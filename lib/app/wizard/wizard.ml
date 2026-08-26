(* What the editor needs of the machine it is editing for. A functor rather than
   arguments threaded through the prompts: only [run] asks, but it asks from the
   bottom of a menu loop. *)
module type ENV = sig
  val config_path : string
  val default_domain : unit -> string option
end

module Make (E : ENV) = struct
  (* Read a JSON value's field, tolerating non-objects and missing keys. *)
  let jfield json key =
    match json with `Assoc l -> List.assoc_opt key l | _ -> None

  let jstr json key =
    match jfield json key with Some (`String s) -> Some s | _ -> None

  let jbool ?(default = false) json key =
    match jfield json key with Some (`Bool b) -> b | _ -> default

  let jint json key =
    match jfield json key with Some (`Int n) -> Some n | _ -> None

  let jlist json key =
    match jfield json key with Some (`List l) -> l | _ -> []

  (* Update key in place (preserving position) or append it. *)
  let assoc_set l key v =
    if List.mem_assoc key l then
      List.map (fun (k, v') -> if k = key then (key, v) else (k, v')) l
    else l @ [(key, v)]

  (* One store's fields from `terraform output -json`. *)
  type tf_store = {
    bucket : string;
    share_url : string;
    fields : (string * string) list;
        (* backend-specific fields terraform fills *)
  }

  (* OpenTofu is a drop-in fork: same [-chdir], same [output -json]. Either one
     answers, so ask them in turn and take the first that does. *)
  let tf_commands = ["terraform"; "tofu"]

  let tf_json exe dir =
    let cmd =
      Printf.sprintf "%s -chdir=%s output -json 2>/dev/null" exe
        (Filename.quote dir)
    in
    let ic = Unix.open_process_in cmd in
    let buf = Buffer.create 4096 in
    let rec drain () =
      match input_line ic with
        | line ->
            Buffer.add_string buf line;
            Buffer.add_char buf '\n';
            drain ()
        | exception End_of_file -> ()
    in
    drain ();
    match Unix.close_process_in ic with
      | Unix.WEXITED 0 -> (
          try Some (Yojson.Basic.from_string (Buffer.contents buf))
          with _ -> None)
      | _ -> None

  let terraform_output dir =
    List.find_map (fun exe -> tf_json exe dir) tf_commands

  let tf_value root name =
    jfield (Option.value (jfield root name) ~default:`Null) "value"

  (* The stores-map output name, the per-store shape and the credential outputs
     all differ by cloud. *)
  let tf_stores_output = function `S3 -> "stores" | `Gcs -> "gcs_stores"

  (* Store keys present in `terraform output` for the given cloud. *)
  let tf_stores root which =
    match tf_value root (tf_stores_output which) with
      | Some (`Assoc l) -> List.map fst l
      | _ -> []

  let tf_lookup root which store =
    match tf_value root (tf_stores_output which) with
      | Some stores -> (
          match jfield stores store with
            | Some s ->
                let str k = Option.value (jstr s k) ~default:"" in
                (* Secrets live in a separate sensitive output, keyed by store. *)
                let secret_from out =
                  Option.bind (tf_value root out) (fun m -> jstr m store)
                in
                let fields =
                  match which with
                    | `S3 -> (
                        let region = str "region" in
                        (if region = "" then [] else [("region", region)])
                        @ [("accessKeyId", str "access_key_id")]
                        @
                          match secret_from "secret_access_keys" with
                          | Some k -> [("secretAccessKey", k)]
                          | None -> [])
                    | `Gcs -> (
                        match secret_from "gcs_service_account_keys" with
                          | Some k -> [("serviceAccountKey", k)]
                          | None -> [])
                in
                Some
                  { bucket = str "bucket"; share_url = str "share_url"; fields }
            | None -> None)
      | None -> None

  (* Redraws menus in place. *)
  let clear_screen () =
    print_string "\027[H\027[2J";
    flush stdout

  let prompt msg def =
    (match def with
      | Some d when d <> "" -> Printf.printf "%s [%s]: %!" msg d
      | _ -> Printf.printf "%s: %!" msg);
    let line = read_line () in
    if line = "" then Option.value def ~default:"" else line

  let prompt_bool ?(default = false) msg =
    Printf.printf "%s [%s]: %!" msg (if default then "Y/n" else "y/N");
    match String.lowercase_ascii (read_line ()) with
      | "y" | "yes" -> true
      | "n" | "no" -> false
      | "" -> default
      | _ -> false

  let prompt_int msg default =
    match int_of_string_opt (prompt msg (Some (string_of_int default))) with
      | Some n when n > 0 -> n
      | _ -> default

  let read_password msg =
    Printf.printf "%s: %!" msg;
    let old_attr = Unix.tcgetattr Unix.stdin in
    Unix.tcsetattr Unix.stdin Unix.TCSAFLUSH
      { old_attr with Unix.c_echo = false };
    match read_line () with
      | s ->
          Unix.tcsetattr Unix.stdin Unix.TCSAFLUSH old_attr;
          print_newline ();
          s
      | exception e ->
          Unix.tcsetattr Unix.stdin Unix.TCSAFLUSH old_attr;
          raise e

  (* Ask until the answer is one of [choices], which the prompt lists. [on_error]
     is for the prompts that have more to say about a wrong answer than the list
     itself already says. *)
  let rec prompt_choice ?(indent = "") ?on_error ~noun label choices default =
    let v =
      prompt
        (Printf.sprintf "%s%s (%s)" indent label (String.concat "/" choices))
        default
    in
    if List.mem v choices then v
    else begin
      (match on_error with
        | Some f -> f v
        | None ->
            Printf.printf "%s  Unknown %s %S — choose one of: %s.\n%!" indent
              noun v
              (String.concat ", " choices));
      prompt_choice ~indent ?on_error ~noun label choices default
    end

  let prompt_symlinks default =
    prompt_choice ~noun:"policy" "Symlinks policy" ["keep"; "follow"; "skip"]
      (Some default)

  (* [unset] is both what is shown for an empty field and what clears it. Sizes are
     optional, so only an answered prompt ever writes one. *)
  let rec prompt_size_opt ?(unset = "none") msg default =
    let def =
      match default with Some n -> Metrics.human_bytes n | None -> unset
    in
    match String.lowercase_ascii (String.trim (prompt msg (Some def))) with
      | "none" | "unlimited" | "default" | "0" | "" -> None
      (* Accepting the offered default keeps the stored value exactly:
         [human_bytes] rounds to one decimal, so re-parsing what it just printed
         would quietly move a size the user did not touch. *)
      | v when v = String.lowercase_ascii def -> default
      | v -> (
          match Conf_parsing.parse_size v with
            | Some n -> Some n
            | None ->
                Printf.printf "  (enter a size like 512K, 8M or 1G, or %S)\n%!"
                  unset;
                prompt_size_opt ~unset msg default)

  (* Suggested cache cap for a new domain; the prompt still takes "none". Editing
     an existing domain shows what it already has. *)
  let default_max_cache = 1024 * 1024 * 1024
  let role_names = List.map Conf_parsing.role_name Conf_parsing.roles

  (* One line each: the differences are the point. *)
  let role_help = function
    | `Main -> "writable source of truth; reads prefer it"
    | `Replica -> "complete copy: every write, read when no main is reachable"
    | `Backfill ->
        "converging copy, filled lazily in the background, never read"
    | `ReadOnly -> "authoritative store read as a fallback, never written"

  let role_of l =
    match List.assoc_opt "role" l with
      | Some (`String s) when Conf_parsing.role_of_string s <> None -> s
      | _ -> "main"

  let prompt_role default =
    prompt_choice ~indent:"  " ~noun:"role" "Role" role_names (Some default)
      ~on_error:(fun v ->
        (* The names alone do not say what a role does; spell them out. *)
        Printf.printf "  Unknown role %S:\n" v;
        List.iter
          (fun r ->
            Printf.printf "    %-10s %s\n%!" (Conf_parsing.role_name r)
              (role_help r))
          Conf_parsing.roles)

  (* Fields a Terraform store fills, which the wizard then skips. Exactly what
     [apply_store_fields] sets. *)
  let store_fields (s : tf_store) =
    "bucket" :: "shareUrl" :: List.map fst s.fields

  let apply_store_fields l (s : tf_store) =
    let l = assoc_set l "bucket" (`String s.bucket) in
    let l =
      List.fold_left (fun l (k, v) -> assoc_set l k (`String v)) l s.fields
    in
    assoc_set l "shareUrl" (`String s.share_url)

  (* Pulls once; nothing about Terraform is persisted. [None] on decline or
     failure. *)
  let terraform_store which =
    let dir = prompt "  Terraform directory" (Some "terraform") in
    let fail msg =
      Printf.printf "  (%s)\n" msg;
      None
    in
    match terraform_output dir with
      | None ->
          fail
            (Printf.sprintf "could not read terraform or tofu output in %s" dir)
      | Some root -> (
          let entries =
            List.filter_map
              (fun k -> Option.map (fun s -> (k, s)) (tf_lookup root which k))
              (tf_stores root which)
          in
          match entries with
            | [] -> fail "no stores found in terraform output"
            | _ -> (
                Printf.printf "  Terraform stores:\n";
                List.iteri
                  (fun i (k, (s : tf_store)) ->
                    Printf.printf "    %d. %-10s %s\n" (i + 1) k s.bucket)
                  entries;
                let choice = prompt "  Choose a store by number" (Some "1") in
                match int_of_string_opt (String.trim choice) with
                  | Some n when n >= 1 && n <= List.length entries ->
                      let k, s = List.nth entries (n - 1) in
                      Printf.printf "  Pulled store %S (bucket=%s).\n" k
                        s.bucket;
                      Some s
                  | _ -> fail "invalid choice"))

  (* Answering blank keeps [current]; with nothing to keep, a required setting
     ([default = None]) is asked again and an optional one ([default = Some ""])
     is omitted.

     [None] therefore says "leave this out of the config", not "the user typed
     nothing". *)
  let rec prompt_field ?(indent = "") ?current (s : Field_spec.t) =
    let label = indent ^ s.label in
    let required = s.default = None in
    let again () = prompt_field ~indent ?current s in
    (* What to offer as the pre-filled answer: what is configured now, else the
       spec's default unless that default is the "omit when blank" marker. *)
    let suggestion =
      match current with
        | Some c -> Some c
        | None -> ( match s.default with Some "" | None -> None | d -> d)
    in
    (* Blank, with nothing already configured to fall back on. *)
    let blank () =
      match current with
        | Some c -> Some (s.name, `String c)
        | None when required ->
            Printf.printf "%s(required — cannot be blank)\n%!" indent;
            again ()
        | None -> None
    in
    match s.typ with
      | `Bool ->
          (* Read the same way the driver will read it, or the box this prompt
             ticks and the setting that takes effect are two different answers to
             one question. *)
          let default =
            Field_spec.bool
              ~default:(Field_spec.bool ~default:false s.default)
              current
          in
          Some (s.name, `Bool (prompt_bool ~default label))
      | `Int -> (
          match prompt label suggestion with
            | "" -> if required then blank () else None
            | v -> (
                match int_of_string_opt v with
                  | Some n -> Some (s.name, `Int n)
                  | None ->
                      Printf.printf "%s(must be a number)\n%!" indent;
                      again ()))
      | `String when s.secret -> (
          let suffix =
            if current <> None then " (blank keeps current)" else ""
          in
          match read_password (label ^ suffix) with
            | "" -> blank ()
            | v -> Some (s.name, `String v))
      | `String -> (
          match prompt label suggestion with
            (* Only a spec saying [Some ""] means a blank leaves the field out; a
               field that is merely optional-with-a-default keeps the empty
               string the user chose. *)
            | "" when current <> None || s.default = Some "" -> blank ()
            | "" when not required -> Some (s.name, `String "")
            | "" -> blank ()
            | v -> Some (s.name, `String v))

  (* A cloud backend is normally a copy of something local, so s3 and gcs default
     to [replica] — but only once there is a main to be a copy of: a domain whose
     backends are all replicas has no source of truth and will not load
     (conf_parsing.ml:validate_roles). *)
  let default_role ~siblings which =
    let is_main b = role_of (match b with `Assoc l -> l | _ -> []) = "main" in
    if which <> None && List.exists is_main siblings then "replica" else "main"

  let prompt_backend ?(siblings = []) () =
    let types = Backend_lwt.types () in
    (* [local] is always compiled in and is the only type that needs no bucket
       and no credentials, so it is the one default that cannot ask for something
       the user does not have yet. Falling back to the first registered type used
       to hand out whichever cloud sorted first. *)
    let default =
      if List.mem "local" types then Some "local" else List.nth_opt types 0
    in
    let backend_type =
      prompt_choice ~indent:"  " ~noun:"backend type" "Backend type" types
        default
    in
    let name = prompt "  Backend name" (Some backend_type) in
    (* Offer Terraform up front, then prompt only the fields it does not
       provide. *)
    let which =
      match backend_type with
        | "s3" -> Some `S3
        | "gcs" -> Some `Gcs
        | _ -> None
    in
    let synced =
      match which with
        | Some w
          when prompt_bool ~default:true
                 "  Fill bucket/keys/share URL from Terraform?" ->
            terraform_store w
        | _ -> None
    in
    let synced_skip =
      match synced with Some s -> store_fields s | None -> []
    in
    let spec = Option.value ~default:[] (Backend_lwt.spec_for backend_type) in
    let fields =
      List.filter_map
        (fun (s : Field_spec.t) ->
          if List.mem s.name synced_skip then None
          else prompt_field ~indent:"  " s)
        spec
    in
    let synced_fields =
      match synced with Some s -> apply_store_fields [] s | None -> []
    in
    let role = prompt_role (default_role ~siblings which) in
    `Assoc
      ([("name", `String name); ("type", `String backend_type)]
      @ synced_fields @ fields
      @ [("role", `String role)])

  (* Backends and frontends are both a numbered list of entries the user builds
     up and then edits; only what an entry holds differs. These two loops are the
     shape they share. *)

  (* Fill a list from empty, one entry at a time. [more] stops the offer when
     there is nothing left worth adding. *)
  let add_loop ~noun ?(more = fun _ -> true) add =
    let items = ref [] in
    let n = ref 1 in
    let continue_ = ref true in
    while !continue_ do
      Printf.printf "\n  %s %d\n" (String.capitalize_ascii noun) !n;
      items := !items @ [add !items];
      incr n;
      continue_ :=
        more !items && prompt_bool (Printf.sprintf "  Add another %s?" noun)
    done;
    !items

  (* Menu over an existing list: edit one, [a]dd, [r]emove, [d]one. [add] and
     [edit] answer [Error msg] to decline with a reason shown in the menu. *)
  let list_menu ~noun ~row ~add ~edit items =
    let items = ref items in
    let running = ref true in
    let status = ref "" in
    while !running do
      clear_screen ();
      Printf.printf "%ss:\n" (String.capitalize_ascii noun);
      if !items = [] then Printf.printf "  (none)\n"
      else
        List.iteri
          (fun i x -> Printf.printf "  %d. %s\n" (i + 1) (row x))
          !items;
      if !status <> "" then Printf.printf "\n%s\n" !status;
      Printf.printf
        "\nEnter a %s number to edit, [a]dd, [r]emove N, or [d]one:\n> %!" noun;
      status := "";
      let parts =
        List.filter (( <> ) "")
          (String.split_on_char ' '
             (String.lowercase_ascii (String.trim (read_line ()))))
      in
      let nth_ok i = i >= 1 && i <= List.length !items in
      match parts with
        | [] | ["d"] -> running := false
        | ["a"] -> (
            match add !items with
              | Ok x -> items := !items @ [x]
              | Error msg -> status := msg)
        | ["r"; n] -> (
            match int_of_string_opt n with
              | Some i when nth_ok i ->
                  items := List.filteri (fun j _ -> j <> i - 1) !items
              | _ -> status := Printf.sprintf "(need a valid %s number)" noun)
        | [n] -> (
            match int_of_string_opt n with
              | Some i when nth_ok i -> (
                  match edit (List.nth !items (i - 1)) with
                    | Ok x ->
                        items :=
                          List.mapi
                            (fun j y -> if j = i - 1 then x else y)
                            !items
                    | Error msg -> status := msg)
              | _ -> status := Printf.sprintf "(unknown action %S)" n)
        | _ -> status := "(unknown action)"
    done;
    !items

  let prompt_backends () =
    add_loop ~noun:"backend" (fun siblings -> prompt_backend ~siblings ())

  (* Per-field editor for one backend, with a Terraform sync action for s3. *)
  let edit_backend b =
    let l = ref (match b with `Assoc l -> l | _ -> []) in
    let get k =
      match List.assoc_opt k !l with
        | Some (`String s) -> s
        | Some (`Bool b) -> string_of_bool b
        | _ -> ""
    in
    let btype = get "type" in
    let which =
      match btype with "s3" -> Some `S3 | "gcs" -> Some `Gcs | _ -> None
    in
    let can_sync = which <> None in
    let spec = Option.value ~default:[] (Backend_lwt.spec_for btype) in
    let running = ref true in
    let status = ref "" in
    while !running do
      clear_screen ();
      Printf.printf "Editing backend: %s (%s)\n\nFields:\n" (get "name") btype;
      Printf.printf "  1. %-16s %s\n" "name:" (get "name");
      List.iteri
        (fun i (s : Field_spec.t) ->
          let v = get s.name in
          Printf.printf "  %d. %-16s %s\n" (i + 2) (s.name ^ ":")
            (if s.secret && v <> "" then "***" else v))
        spec;
      let role_n = List.length spec + 2 in
      Printf.printf "  %d. %-16s %s\n" role_n "role:" (role_of !l);
      if can_sync then
        Printf.printf "  [t] sync bucket/keys/share URL from Terraform\n";
      if !status <> "" then Printf.printf "\n%s\n" !status;
      Printf.printf "\nEnter a field number to edit%s, or [d]one:\n> %!"
        (if can_sync then ", [t] to sync" else "");
      status := "";
      let input = String.lowercase_ascii (String.trim (read_line ())) in
      match input with
        | "d" | "" -> running := false
        | "t" when can_sync -> (
            match terraform_store (Option.get which) with
              | Some s -> l := apply_store_fields !l s
              | None -> ())
        | "1" ->
            l :=
              assoc_set !l "name"
                (`String (prompt "Backend name" (Some (get "name"))))
        | _ -> (
            match int_of_string_opt input with
              | Some n when n = role_n ->
                  l := assoc_set !l "role" (`String (prompt_role (role_of !l)))
              | Some n when n >= 2 && n <= List.length spec + 1 -> (
                  let s = List.nth spec (n - 2) in
                  match prompt_field s ~current:(get s.name) with
                    | Some (k, v) -> l := assoc_set !l k v
                    | None -> l := List.remove_assoc s.name !l)
              | _ -> status := Printf.sprintf "(unknown field %S)" input)
    done;
    `Assoc !l

  let edit_backends backends =
    list_menu ~noun:"backend"
      ~row:(fun b ->
        Printf.sprintf "%s (%s) [%s]"
          (Option.value (jstr b "name") ~default:"?")
          (Option.value (jstr b "type") ~default:"?")
          (role_of (match b with `Assoc l -> l | _ -> [])))
      ~add:(fun siblings ->
        Printf.printf "\nNew backend\n";
        Ok (prompt_backend ~siblings ()))
      ~edit:(fun b -> Ok (edit_backend b))
      backends

  let backend_summary = function
    | [] -> "(none)"
    | bs ->
        String.concat ", "
          (List.map (fun b -> Option.value (jstr b "type") ~default:"?") bs)

  (* A frontend entry is a bare type-name string or an object with a "type" key. *)
  let frontend_type_of = function `String s -> Some s | j -> jstr j "type"

  let frontend_summary = function
    | [] -> "(none)"
    | fs ->
        let opt_str k = function
          | `String "" -> None
          | `String _ when k = "secret" -> Some (k ^ "=***")
          | `String s -> Some (k ^ "=" ^ s)
          | `Bool b -> Some (k ^ "=" ^ string_of_bool b)
          | `Int n -> Some (k ^ "=" ^ string_of_int n)
          | _ -> None
        in
        String.concat ", "
          (List.map
             (fun j ->
               let name = Option.value (frontend_type_of j) ~default:"?" in
               match j with
                 | `Assoc l -> (
                     match
                       List.filter_map
                         (fun (k, v) ->
                           if k = "type" then None else opt_str k v)
                         l
                     with
                       | [] -> name
                       | opts ->
                           Printf.sprintf "%s(%s)" name (String.concat "," opts)
                     )
                 | _ -> name)
             fs)

  (* A frontend with no options set is emitted as a bare type-name string, else as
     [{"type": name, ...options}]. *)
  let frontend_entry name opts =
    if opts = [] then `String name else `Assoc (("type", `String name) :: opts)

  (* Sorted, as {!Backend_lwt.types} is: [Frontend.names] comes out of a hashtable, so
     without this the wizard asks in whatever order the frontends hashed into. *)
  let frontend_types () = List.sort compare (Frontend.names ())

  (* The frontend a fresh domain most likely wants: the platform's own mount if
     one is compiled in, else whatever is — on Android that is the command-driven
     frontend, which is the only one there. *)
  let preferred_frontend types =
    match
      List.find_opt (fun n -> List.mem n types) ["fuse"; "file_provider"]
    with
      | Some n -> Some n
      | None -> List.nth_opt types 0

  (* Mirrors {!prompt_backend}: choose a type, then fill in that type's fields.
     Unlike a backend, a frontend has no name and no role — the type names it, and
     a domain runs at most one of each, so [taken] drops the ones already
     configured from the offer. *)
  let prompt_frontend ?(taken = []) () =
    let types =
      List.filter (fun n -> not (List.mem n taken)) (frontend_types ())
    in
    let ftype =
      prompt_choice ~indent:"  " ~noun:"frontend type" "Frontend type" types
        (preferred_frontend types)
    in
    let opts =
      List.filter_map
        (fun (s : Field_spec.t) -> prompt_field ~indent:"  " s)
        (Frontend.spec_for ftype)
    in
    frontend_entry ftype opts

  let taken_frontends fs = List.filter_map frontend_type_of fs

  (* Every compiled-in frontend configured: nothing left to offer. *)
  let all_frontends_taken fs =
    List.length (taken_frontends fs) >= List.length (frontend_types ())

  let prompt_frontends () =
    add_loop ~noun:"frontend"
      ~more:(fun fs -> not (all_frontends_taken fs))
      (fun fs -> prompt_frontend ~taken:(taken_frontends fs) ())

  (* Per-field editor for one frontend. Its type is fixed, as a backend's is. *)
  let edit_frontend f =
    let ftype = Option.value (frontend_type_of f) ~default:"" in
    let l =
      ref (match f with `Assoc l -> List.remove_assoc "type" l | _ -> [])
    in
    let get k =
      match List.assoc_opt k !l with
        | Some (`String s) -> s
        | Some (`Bool b) -> string_of_bool b
        | Some (`Int n) -> string_of_int n
        | _ -> ""
    in
    let spec = Frontend.spec_for ftype in
    let running = ref true in
    let status = ref "" in
    while !running do
      clear_screen ();
      Printf.printf "Editing frontend: %s\n\nFields:\n" ftype;
      List.iteri
        (fun i (s : Field_spec.t) ->
          let v = get s.name in
          Printf.printf "  %d. %-16s %s\n" (i + 1) (s.name ^ ":")
            (if s.secret && v <> "" then "***" else v))
        spec;
      if !status <> "" then Printf.printf "\n%s\n" !status;
      Printf.printf "\nEnter a field number to edit, or [d]one:\n> %!";
      status := "";
      let input = String.lowercase_ascii (String.trim (read_line ())) in
      match input with
        | "d" | "" -> running := false
        | _ -> (
            match int_of_string_opt input with
              | Some n when n >= 1 && n <= List.length spec -> (
                  let s = List.nth spec (n - 1) in
                  match prompt_field s ~current:(get s.name) with
                    | Some (k, v) -> l := assoc_set !l k v
                    | None -> l := List.remove_assoc s.name !l)
              | _ -> status := Printf.sprintf "(unknown field %S)" input)
    done;
    frontend_entry ftype !l

  let edit_frontends frontends =
    list_menu ~noun:"frontend"
      ~row:(fun f -> frontend_summary [f])
      ~add:(fun fs ->
        if all_frontends_taken fs then
          Error "(every compiled-in frontend is already configured)"
        else begin
          Printf.printf "\nNew frontend\n";
          Ok (prompt_frontend ~taken:(taken_frontends fs) ())
        end)
      ~edit:(fun f ->
        let ftype = Option.value (frontend_type_of f) ~default:"" in
        (* A frontend with no options — android — has no editor to open. *)
        if Frontend.spec_for ftype = [] then
          Error (Printf.sprintf "(%s has no options)" ftype)
        else Ok (edit_frontend f))
      frontends

  (* A new domain ([existing = None]) is filled in linearly; an existing one goes
     through a per-field menu, so untouched fields keep their values. *)
  let edit_domain existing =
    let cur k d =
      Option.value (Option.bind existing (fun j -> jstr j k)) ~default:d
    in
    let curbool ?(default = false) k =
      match existing with Some j -> jbool ~default j k | None -> default
    in
    let name = ref (cur "name" "default") in
    (* History costs storage the backend expires on its own; losing an overwrite
       costs the file. A new domain therefore keeps versions unless told not to. *)
    let versioning = ref (curbool ~default:true "versioning") in
    let symlinks = ref (cur "symlinks" "keep") in
    let read_only = ref (curbool "readOnly") in
    let size_field name =
      ref
        (match Option.bind existing (fun j -> jfield j name) with
          | Some (`Int n) when n > 0 -> Some n
          | Some (`String s) -> Conf_parsing.parse_size s
          | _ -> None)
    in
    let chunk_size = size_field "chunkSize" in
    let cache_chunk_size = size_field "cacheChunkSize" in
    let max_cache =
      ref
        (match Option.bind existing (fun j -> jfield j "maxCache") with
          | Some (`Int n) when n > 0 -> Some n
          | Some (`String s) -> Conf_parsing.parse_size s
          | _ -> None)
    in
    let backends =
      ref (match existing with Some j -> jlist j "backends" | None -> [])
    in
    let frontends =
      ref (match existing with Some j -> jlist j "frontends" | None -> [])
    in
    (match existing with
      | None ->
          name := prompt "Domain name" (Some !name);
          versioning :=
            prompt_bool ~default:!versioning
              "Enable versioning (keep version history)?";
          symlinks := prompt_symlinks !symlinks;
          read_only :=
            prompt_bool ~default:!read_only
              "Read-only mount (block all local writes)?";
          chunk_size :=
            prompt_size_opt ~unset:"default"
              "Chunk size (smaller helps random access; larger favors \
               throughput)"
              !chunk_size;
          cache_chunk_size :=
            prompt_size_opt ~unset:"default"
              "Cache chunk size (chunks grouped this big on local disk; larger \
               cuts I/O latency)"
              !cache_chunk_size;
          (* An uncapped cache grows to the size of whatever gets read, and the
             first notice is a full disk. Cached chunks are re-fetchable, so a cap
             costs downloads, never data. *)
          max_cache :=
            prompt_size_opt "Max local cache size (\"none\" = unlimited)"
              (Some default_max_cache);
          backends := prompt_backends ();
          frontends := prompt_frontends ()
      | Some _ ->
          let running = ref true in
          let status = ref "" in
          while !running do
            clear_screen ();
            Printf.printf "Editing domain: %s\n\nFields:\n" !name;
            Printf.printf "  1. name:        %s\n" !name;
            Printf.printf "  2. versioning:  %b\n" !versioning;
            Printf.printf "  3. symlinks:    %s\n" !symlinks;
            Printf.printf "  4. read-only:   %b\n" !read_only;
            let size_str = function
              | Some n -> Metrics.human_bytes n
              | None -> "default"
            in
            Printf.printf "  5. chunk size:  %s\n" (size_str !chunk_size);
            Printf.printf "  6. cache chunk: %s\n" (size_str !cache_chunk_size);
            Printf.printf "  7. max cache:   %s\n"
              (match !max_cache with
                | Some n -> Metrics.human_bytes n
                | None -> "none");
            Printf.printf "  8. backends:    %s\n" (backend_summary !backends);
            Printf.printf "  9. frontends:   %s\n" (frontend_summary !frontends);
            if !status <> "" then Printf.printf "\n%s\n" !status;
            Printf.printf "\nEnter a field number to edit, or [d]one:\n> %!";
            status := "";
            match String.lowercase_ascii (String.trim (read_line ())) with
              | "1" -> name := prompt "Domain name" (Some !name)
              | "2" ->
                  versioning :=
                    prompt_bool ~default:!versioning "Enable versioning?"
              | "3" -> symlinks := prompt_symlinks !symlinks
              | "4" ->
                  read_only :=
                    prompt_bool ~default:!read_only "Read-only mount?"
              | "5" ->
                  chunk_size :=
                    prompt_size_opt ~unset:"default" "Chunk size" !chunk_size
              | "6" ->
                  cache_chunk_size :=
                    prompt_size_opt ~unset:"default" "Cache chunk size"
                      !cache_chunk_size
              | "7" ->
                  max_cache :=
                    prompt_size_opt
                      "Max local cache size (\"none\" = unlimited)" !max_cache
              | "8" -> backends := edit_backends !backends
              | "9" -> frontends := edit_frontends !frontends
              | "d" | "" -> running := false
              | other -> status := Printf.sprintf "(unknown field %S)" other
          done);
    `Assoc
      ([
         ("name", `String !name);
         ("versioning", `Bool !versioning);
         ("symlinks", `String !symlinks);
         ("readOnly", `Bool !read_only);
       ]
      (* Written as plain byte counts: the config is data. A hand-written "8M" is
         still accepted on the way in — see {!Conf_parsing.parse_size}. *)
      @ (match !chunk_size with
        | Some n -> [("chunkSize", `Int n)]
        | None -> [])
      @ (match !cache_chunk_size with
        | Some n -> [("cacheChunkSize", `Int n)]
        | None -> [])
      @ (match !max_cache with Some n -> [("maxCache", `Int n)] | None -> [])
      @ [("backends", `List !backends); ("frontends", `List !frontends)])

  (* Serialize globals + domains to [path] with 0600 perms. *)
  let write_config ~path ~client_name ~max_uploads ~max_chunk_buffers
      ~max_downloads ~tls ~domains =
    Io_lwt.Fs.mkdir_p_sync (Filename.dirname path);
    let json =
      `Assoc
        ([
           ("name", `String client_name);
           ("maxUploads", `Int max_uploads);
           ("maxChunkBuffers", `Int max_chunk_buffers);
           ("maxDownloads", `Int max_downloads);
         ]
        @ (match tls with Some t -> [("tls", `String t)] | None -> [])
        @ [("domains", `List domains)])
    in
    (* Checked with the reader's own rules before it lands, so this cannot write
       a file the daemon then refuses to start on. *)
    (match Conf_parsing.of_json json with
      | _ -> ()
      | exception Failure msg ->
          Printf.eprintf "Refusing to write an invalid config: %s\n" msg;
          exit 1);
    let oc = open_out path in
    output_string oc (Yojson.Basic.pretty_to_string json);
    output_char oc '\n';
    close_out oc;
    Unix.chmod path 0o600

  let run () =
    Printf.printf "tsync configuration\n-------------------\n";
    let config_path = E.config_path in
    let existing_root =
      if Sys.file_exists config_path then (
        match Yojson.Basic.from_file config_path with
          | j -> Some j
          | exception _ ->
              Printf.eprintf
                "Existing config at %s is not valid JSON; refusing to overwrite.\n"
                config_path;
              exit 1)
      else None
    in
    let client_name =
      ref
        (Option.value
           (Option.bind existing_root (fun r -> jstr r "name"))
           ~default:(Unix.gethostname ()))
    in
    let max_uploads =
      ref
        (Option.value
           (Option.bind existing_root (fun r -> jint r "maxUploads"))
           ~default:Conf_parsing.default_max_uploads)
    in
    let max_chunk_buffers =
      ref
        (Option.value
           (Option.bind existing_root (fun r -> jint r "maxChunkBuffers"))
           ~default:!max_uploads)
    in
    let max_downloads =
      ref
        (Option.value
           (Option.bind existing_root (fun r -> jint r "maxDownloads"))
           ~default:Conf_parsing.default_max_downloads)
    in
    let tls = ref (Option.bind existing_root (fun r -> jstr r "tls")) in
    let domains =
      ref (match existing_root with Some r -> jlist r "domains" | None -> [])
    in
    let edit_globals () =
      client_name := prompt "Client name" (Some !client_name);
      max_uploads := prompt_int "Max concurrent uploads" !max_uploads;
      (* Times the chunk size, this is what uploading costs in memory. *)
      max_chunk_buffers :=
        prompt_int "Max chunk buffers held in memory" !max_chunk_buffers;
      max_downloads := prompt_int "Max concurrent downloads" !max_downloads;
      (* Only worth asking when the build has more than one backend. "auto"
           leaves it unset, taking the preferred one at startup, which survives a
           build dropping a backend. *)
      let available = Tls_conf.available () in
      if List.length available >= 2 then begin
        let choice =
          prompt
            (Printf.sprintf "TLS backend for S3 (auto/%s)"
               (String.concat "/" available))
            (Some (Option.value !tls ~default:"auto"))
        in
        tls := if List.mem choice available then Some choice else None
      end
    in
    (* A brand-new config: gather globals and the first domain up front. *)
    if existing_root = None then begin
      edit_globals ();
      Printf.printf "\nDomain 1\n";
      domains := [edit_domain None]
    end;
    (* On entry, select the default domain if one is set, else the first. *)
    let default_domain = E.default_domain () in
    let selected =
      ref
        (match
           Option.bind default_domain (fun name ->
               List.find_index (fun d -> jstr d "name" = Some name) !domains)
         with
          | Some i -> i
          | None -> if !domains = [] then -1 else 0)
    in
    let list_domains () =
      if !domains = [] then Printf.printf "  (no domains)\n"
      else
        List.iteri
          (fun i d ->
            let name = Option.value (jstr d "name") ~default:"?" in
            let btype =
              match jlist d "backends" with
                | b :: _ -> Option.value (jstr b "type") ~default:"?"
                | [] -> "none"
            in
            let dflt =
              if default_domain = Some name then " [default]" else ""
            in
            Printf.printf "%s %d. %s (%s)%s\n"
              (if i = !selected then ">" else " ")
              (i + 1) name btype dflt)
          !domains
    in
    let replace_nth i v = List.mapi (fun j x -> if j = i then v else x) in
    let remove_nth i = List.filteri (fun j _ -> j <> i) in
    let selected_name () =
      if !selected >= 0 && !selected < List.length !domains then
        Option.value (jstr (List.nth !domains !selected) "name") ~default:"?"
      else "(none)"
    in
    let saved = ref false in
    let running = ref true in
    let status = ref "" in
    while !running do
      clear_screen ();
      Printf.printf "tsync configuration\n-------------------\n\nDomains:\n";
      list_domains ();
      Printf.printf "\nSelected: %s\n" (selected_name ());
      if !status <> "" then Printf.printf "\n%s\n" !status;
      Printf.printf
        "\n\
         Enter a domain number to select, or an action:\n\
        \  [a]dd  [e]dit selected  [r]emove selected  [g]lobals  [w]rite  [q]uit\n\
         > %!";
      let action = String.lowercase_ascii (String.trim (read_line ())) in
      let has_sel = !selected >= 0 && !selected < List.length !domains in
      status := "";
      match int_of_string_opt action with
        | Some n ->
            if n >= 1 && n <= List.length !domains then selected := n - 1
            else status := Printf.sprintf "(no domain %d)" n
        | None -> (
            match action with
              | "a" ->
                  domains := !domains @ [edit_domain None];
                  selected := List.length !domains - 1
              | "e" ->
                  if has_sel then
                    domains :=
                      replace_nth !selected
                        (edit_domain (Some (List.nth !domains !selected)))
                        !domains
                  else status := "(select a domain first)"
              | "r" ->
                  if has_sel then begin
                    domains := remove_nth !selected !domains;
                    if !selected >= List.length !domains then
                      selected := List.length !domains - 1
                  end
                  else status := "(select a domain first)"
              | "g" -> edit_globals ()
              | "w" ->
                  if !domains = [] then
                    status := "(add at least one domain before writing)"
                  else begin
                    running := false;
                    saved := true
                  end
              | "q" ->
                  if prompt_bool "Quit without saving?" then running := false
              | "" -> ()
              | other -> status := Printf.sprintf "(unknown action %S)" other)
    done;
    if not !saved then Printf.printf "Aborted; config left untouched.\n"
    else begin
      write_config ~path:config_path ~client_name:!client_name
        ~max_uploads:!max_uploads ~max_chunk_buffers:!max_chunk_buffers
        ~max_downloads:!max_downloads ~tls:!tls ~domains:!domains;
      Printf.printf "\nConfig written to %s\n" config_path;
      print_endline "Run `tsync restart` to apply it."
    end
end
