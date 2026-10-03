open Tsync_core

type prompt = { label : string; default : string option; secret : bool }
type io = { ask : prompt -> string; say : string -> unit }
type json = Yojson.Safe.t

let fields = function `Assoc l -> l | _ -> []
let get j k = List.assoc_opt k (fields j)

(* Keys keep their place; a new key goes last. *)
let set j k v =
  let l = fields j in
  if List.mem_assoc k l then
    `Assoc (List.map (fun (k', x) -> if k' = k then (k, v) else (k', x)) l)
  else `Assoc (l @ [(k, v)])

let unset j k = `Assoc (List.filter (fun (k', _) -> k' <> k) (fields j))

let show = function
  | `String s -> Some s
  | `Bool b -> Some (string_of_bool b)
  | `Int i -> Some (string_of_int i)
  | `Float f -> Some (Printf.sprintf "%g" f)
  | `List l ->
      Some
        (String.concat ", "
           (List.filter_map (function `String s -> Some s | _ -> None) l))
  | _ -> None

let typed (kind : Field_spec.kind) s : (json, string) result =
  match kind with
    | String | Path -> Ok (`String s)
    | Size -> (
        match Config.parse_size s with
          | Some _ -> Ok (`String s)
          | None -> Error "a size such as 8M or 1.5 GiB")
    | Bool -> (
        match Config.bool_of_string_opt s with
          | Some b -> Ok (`Bool b)
          | None -> Error "answer yes or no")
    | Int -> (
        match int_of_string_opt s with
          | Some i -> Ok (`Int i)
          | None -> Error "a whole number")
    | Float -> (
        match float_of_string_opt s with
          | Some f -> Ok (`Float f)
          | None -> Error "a number")
    | List ->
        Ok
          (`List
             (List.filter_map
                (fun x ->
                  match String.trim x with "" -> None | x -> Some (`String x))
                (String.split_on_char ',' s)))

(* Blank keeps the current value; a required field without one is asked
   again; a check's refusal is said and asked again. A default the parser
   applies itself stays out of the file; [write_default] writes the wizard's
   own (§5.9) and those the parser requires. *)
let rec field io j ?(secret = false) ?(required = false)
    ?(check = fun _ -> None) ?(write_default = false) ?default name label kind =
  let current = Option.bind (get j name) show in
  let shown = if secret && current <> None then Some "(kept)" else current in
  let answer =
    String.trim
      (io.ask
         {
           label;
           default = (match shown with Some _ -> shown | None -> default);
           secret;
         })
  in
  let value =
    if answer = "" then (
      match (current, default) with
        | Some _, _ -> None
        | None, Some d when write_default -> Some d
        | None, _ -> None)
    else Some answer
  in
  match value with
    | None when required && current = None ->
        io.say (label ^ " is required");
        field io j ~secret ~required ~check ~write_default ?default name label
          kind
    | None -> j
    | Some v -> (
        match
          Option.fold
            ~none:(typed kind v |> Result.map Option.some)
            ~some:(fun e -> Error e)
            (check v)
        with
          | Ok (Some x) -> set j name x
          | Ok None -> j
          | Error e ->
              io.say (label ^ ": " ^ e);
              field io j ~secret ~required ~check ~write_default ?default name
                label kind)

let spec_fields io j (specs : Field_spec.field list) =
  List.fold_left
    (fun j (f : Field_spec.field) ->
      field io j ~secret:f.secret ~required:f.required ~check:f.check
        ?default:f.default f.name f.label f.kind)
    j specs

let choose io ~label ~default options =
  let rec go () =
    let a =
      String.trim
        (io.ask
           {
             label = label ^ " (" ^ String.concat ", " options ^ ")";
             default = Some default;
             secret = false;
           })
    in
    let a = if a = "" then default else a in
    if List.mem a options then a
    else (
      io.say (a ^ " is not one of " ^ String.concat ", " options);
      go ())
  in
  go ()

(* §5.9: optional filling of a cloud store's fields from an infrastructure
   tool's outputs, whose names match the driver's fields. *)
let terraform_outputs io =
  let dir =
    String.trim
      (io.ask
         {
           label =
             "fill from terraform or tofu outputs in directory (blank to skip)";
           default = None;
           secret = false;
         })
  in
  if dir = "" then []
  else (
    let run tool =
      let cmd =
        Printf.sprintf "%s -chdir=%s output -json 2>/dev/null" tool
          (Filename.quote dir)
      in
      let ic = Unix.open_process_in cmd in
      let out = In_channel.input_all ic in
      match Unix.close_process_in ic with
        | WEXITED 0 -> (
            match Yojson.Safe.from_string out with
              | `Assoc l ->
                  Some
                    (List.filter_map
                       (fun (k, o) ->
                         match get o "value" with
                           | Some (`String s) -> Some (k, s)
                           | _ -> None)
                       l)
              | _ | (exception Yojson.Json_error _) -> None)
        | _ -> None
    in
    match run "terraform" with
      | Some l -> l
      | None -> (
          match run "tofu" with
            | Some l -> l
            | None ->
                io.say "no outputs could be read there";
                []))

let backend io ~has_main b =
  let types = Tsync_store.Driver.names () in
  let btype =
    choose io ~label:"type"
      ~default:(Option.value ~default:"local" (Option.bind (get b "type") show))
      types
  in
  let b = set b "type" (`String btype) in
  let b = field io b ~required:true "name" "backend name" String in
  let cloud = btype <> "local" in
  let b =
    field io b "role" "role (main, replica, backfill, readOnly)"
      ~default:(if cloud && has_main then "replica" else "main")
      ~write_default:true
      ~check:(fun r ->
        if List.mem r ["main"; "replica"; "backfill"; "readOnly"] then None
        else Some "one of main, replica, backfill, readOnly")
      String
  in
  let b = if cloud then field io b "link" "link (blank: none)" String else b in
  match Tsync_store.Driver.find btype with
    | None -> b
    | Some d ->
        let filled =
          if btype = "s3" || btype = "gcs" then terraform_outputs io else []
        in
        let b =
          List.fold_left
            (fun b (k, v) ->
              if
                get b k = None
                && List.exists
                     (fun (f : Field_spec.field) -> f.name = k)
                     d.fields
              then set b k (`String v)
              else b)
            b filled
        in
        spec_fields io b d.fields

let list_of j k = match get j k with Some (`List l) -> l | _ -> []

let edit_list io ~noun ~describe ~one items =
  let rec loop items =
    List.iteri
      (fun i x -> io.say (Printf.sprintf "  %d. %s" (i + 1) (describe x)))
      items;
    match
      String.trim
        (io.ask
           {
             label = Printf.sprintf "%s: [a]dd [e]dit N [r]emove N [d]one" noun;
             default = Some "d";
             secret = false;
           })
    with
      | "" | "d" -> items
      | "a" -> loop (items @ [one items (`Assoc [])])
      | s -> (
          match String.split_on_char ' ' s with
            | [(("e" | "r") as c); n] -> (
                match int_of_string_opt n with
                  | Some i when i >= 1 && i <= List.length items ->
                      if c = "e" then
                        loop
                          (List.mapi
                             (fun k x -> if k = i - 1 then one items x else x)
                             items)
                      else loop (List.filteri (fun k _ -> k <> i - 1) items)
                  | _ ->
                      io.say "no such number";
                      loop items)
            | _ ->
                io.say "a, e N, r N or d";
                loop items)
  in
  loop items

let domain io d =
  let d = field io d ~required:true "name" "domain name" String in
  let d =
    field io d "versioning" "versioning" ~default:"true" ~write_default:true
      Bool
  in
  let d =
    field io d "symlinks" "symlinks (keep, follow, skip)" ~default:"keep"
      ~write_default:true
      ~check:(fun s ->
        if List.mem s ["keep"; "follow"; "skip"] then None
        else Some "keep, follow or skip")
      String
  in
  let d = field io d "readOnly" "read-only" ~default:"false" Bool in
  let d = field io d "chunkSize" "chunk size (blank: the store's)" Size in
  let d =
    field io d "cacheChunkSize" "cache chunk size (blank: default)" Size
  in
  let d =
    field io d "maxCache" "cache limit" ~default:"1 GiB" ~write_default:true
      Size
  in
  let backends =
    edit_list io ~noun:"backends"
      ~describe:(fun b ->
        Printf.sprintf "%s (%s, %s)"
          (Option.value ~default:"?" (Option.bind (get b "name") show))
          (Option.value ~default:"?" (Option.bind (get b "type") show))
          (Option.value ~default:"main" (Option.bind (get b "role") show)))
      ~one:(fun others b ->
        let has_main =
          List.exists
            (fun o ->
              o != b
              && Option.bind (get o "role") show <> Some "replica"
              && Option.bind (get o "role") show <> Some "backfill"
              && Option.bind (get o "role") show <> Some "readOnly")
            others
        in
        backend io ~has_main b)
      (list_of d "backends")
  in
  let d = set d "backends" (`List backends) in
  let types = Frontend.names () in
  let frontends =
    edit_list io ~noun:"frontends"
      ~describe:(function
        | `String t -> t
        | f -> Option.value ~default:"?" (Option.bind (get f "type") show))
      ~one:(fun _ f ->
        let f =
          match f with `String t -> `Assoc [("type", `String t)] | f -> f
        in
        let t =
          choose io ~label:"frontend"
            ~default:
              (Option.value ~default:(List.hd types)
                 (Option.bind (get f "type") show))
            types
        in
        let f = set f "type" (`String t) in
        let f =
          match Frontend.find t with
            | Some fe -> spec_fields io f fe.fields
            | None -> f
        in
        if fields f = [("type", `String t)] then `String t else f)
      (list_of d "frontends")
  in
  set d "frontends" (`List frontends)

let links_used j =
  List.concat_map
    (fun d ->
      List.filter_map
        (fun b ->
          match get b "link" with Some (`String l) -> Some l | _ -> None)
        (list_of d "backends"))
    (list_of j "domains")
  |> List.sort_uniq compare

let globals io j =
  let j =
    field io j "name" "client name" ~default:(Config.hostname ()) String
  in
  let j = field io j "maxUploads" "uploads at once" ~default:"4" Int in
  let uploads =
    Option.value ~default:"4" (Option.bind (get j "maxUploads") show)
  in
  let j = field io j "maxChunkBuffers" "chunk buffers" ~default:uploads Int in
  let j = field io j "maxDownloads" "downloads at once" ~default:"8" Int in
  let uplink = Option.value ~default:(`Assoc []) (get j "uplink") in
  let uplink =
    field io uplink "enabled" "govern uploads to the network's capacity"
      ~default:"true" Bool
  in
  let j =
    if fields uplink = [] then unset j "uplink" else set j "uplink" uplink
  in
  let links = Option.value ~default:(`Assoc []) (get j "links") in
  let links =
    List.fold_left
      (fun links l ->
        let s = Option.value ~default:(`Assoc []) (get links l) in
        let s =
          field io s "maxRate"
            (Printf.sprintf "%s: most bytes per second (blank: no ceiling)" l)
            Int
        in
        if fields s = [] then links else set links l s)
      links (links_used j)
  in
  let j = if fields links = [] then unset j "links" else set j "links" links in
  field io j "tls" "TLS implementation (openssl, native)" ~default:"openssl"
    ~check:(fun s ->
      if List.mem s ["openssl"; "native"] then None
      else Some "openssl or native")
    String

let describe_domain d =
  Printf.sprintf "%s: %d backends"
    (Option.value ~default:"?" (Option.bind (get d "name") show))
    (List.length (list_of d "backends"))

let edit io start =
  let j =
    match start with
      | Some (`Assoc _ as j) -> j
      | Some _ -> Fail.raise_ Fail.Invalid "the config is not a JSON object"
      | None ->
          io.say
            "A new config: first the settings for this machine, then a domain.";
          let j = globals io (`Assoc []) in
          set j "domains" (`List [domain io (`Assoc [])])
  in
  let rec loop j =
    let ds = list_of j "domains" in
    io.say "Domains:";
    List.iteri
      (fun i d ->
        io.say (Printf.sprintf "  %d. %s" (i + 1) (describe_domain d)))
      ds;
    match
      String.trim
        (io.ask
           {
             label = "[a]dd [e]dit N [r]emove N [g]lobals [w]rite [q]uit";
             default = None;
             secret = false;
           })
    with
      | "a" -> loop (set j "domains" (`List (ds @ [domain io (`Assoc [])])))
      | "g" -> loop (globals io j)
      | "w" -> Some j
      | "q" -> None
      | s -> (
          match String.split_on_char ' ' s with
            | [(("e" | "r") as c); n] -> (
                match int_of_string_opt n with
                  | Some i when i >= 1 && i <= List.length ds ->
                      let ds =
                        if c = "e" then
                          List.mapi
                            (fun k d -> if k = i - 1 then domain io d else d)
                            ds
                        else List.filteri (fun k _ -> k <> i - 1) ds
                      in
                      loop (set j "domains" (`List ds))
                  | _ ->
                      io.say "no such domain";
                      loop j)
            | _ ->
                io.say "a, e N, r N, g, w or q";
                loop j)
  in
  loop j

let prepare j =
  let used = links_used j in
  let j =
    match get j "links" with
      | Some (`Assoc l) ->
          let l = List.filter (fun (k, _) -> List.mem k used) l in
          if l = [] then unset j "links" else set j "links" (`Assoc l)
      | _ -> j
  in
  match Config.of_json j with
    | _ -> Ok j
    | exception Config.Invalid e -> Error e
