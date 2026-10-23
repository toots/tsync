(* tsync passwords <verb> (spec extensions/passwords §9, §10): the CLI, and the
   native-messaging bridge browsers start. *)
open Cmdliner
open Tsync_core
open Tsync_config
open Extension_cmds
module P = Tsync_owner.Protocol
module Passwords = Tsync_vault.Passwords

let extension = "passwords"
let write_domain ?name = write_domain ?name ~extension
let each ?name = each ?name ~extension

let call d action args =
  Vault_cmds.ask d (P.Extension { action = "passwords_" ^ action; args })

let s v = `String v
let field = Tsync_ipc.Ipc.field
let member j k = match j with `Assoc l -> List.assoc_opt k l | _ -> None
let say fmt = Printf.printf (fmt ^^ "\n%!")

let from_stdin v =
  if v = "-" then Option.value ~default:"" (In_channel.input_line stdin) else v

let records reply =
  match List.assoc_opt "records" reply with Some (`List l) -> l | _ -> []

(* README §6.1: an id names the record of the one domain that holds it. *)
let holder ?name config id =
  match name with
    | Some n -> Cli.domain ~name:n config
    | None -> (
        match
          List.filter
            (fun (_, reply) ->
              List.exists (fun row -> field row "id" = Some id) (records reply))
            (each config (fun d -> call d "list" []))
        with
          | [(d, _)] -> d
          | [] -> Fail.absent "no record %s" id
          | l ->
              Fail.invalid "%s is in %s: pick one with --domain" id
                (String.concat ", " (List.map (fun (d, _) -> dname d) l)))

let opt_string name ~doc =
  Arg.(value & opt (some string) None & info [name] ~docv:"TEXT" ~doc)

let urls_arg =
  Arg.(
    value & opt_all string []
    & info ["url"] ~docv:"SITE" ~doc:"A site of the login; repeat for several.")

let password_arg =
  opt_string "password"
    ~doc:
      "The password; - reads it from standard input. Asked without echo when \
       neither this nor --generate is given."

let generate_arg =
  let length =
    Arg.(
      value
      & opt (some int) None
      & info ["generate"] ~docv:"LENGTH"
          ~doc:"Generate a password of LENGTH characters (§5).")
  and words =
    Arg.(
      value
      & opt (some int) None
      & info ["words"] ~docv:"N"
          ~doc:"Generate a password of N words, 4 to 12 (§5).")
  in
  Term.(const (fun length words -> (length, words)) $ length $ words)

let no_symbols =
  Arg.(
    value & flag & info ["no-symbols"] ~doc:"Generate letters and digits only.")

(* §5: a password typed, given or generated, one of them or none. *)
let secret_of ~password ~generate =
  match (password, generate) with
    | Some p, (None, None) -> Some (`Password p)
    | None, (Some length, None) -> Some (`Generate (`Length length))
    | None, (None, Some words) -> Some (`Generate (`Words words))
    | None, (None, None) -> None
    | _, (Some _, Some _) -> Fail.invalid "give --generate or --words, not both"
    | Some _, _ -> Fail.invalid "give --password or a generated one, not both"

let generate_json ~no_symbols = function
  | `Length length ->
      `Assoc [("length", `Int length); ("symbols", `Bool (not no_symbols))]
  | `Words words -> `Assoc [("words", `Int words)]

let secret_args ~no_symbols ~ask_if_absent secret =
  match secret with
    | Some (`Password p) -> [("password", s (from_stdin p))]
    | Some (`Generate how) -> [("generate", generate_json ~no_symbols how)]
    | None when ask_if_absent ->
        [
          ( "password",
            s (Vault_cmds.read_passphrase ~prompt:"password" ~stdin:false ()) );
        ]
    | None -> []

(* §2.2: [--field NAME=VALUE] and [--secret-field NAME], its value asked
   without echo; [None] when neither is given, so an edit keeps the list. *)
let fields_arg =
  let plain =
    Arg.(
      value & opt_all string []
      & info ["field"] ~docv:"NAME=VALUE"
          ~doc:
            "A custom field; repeat for several. On edit, the list replaces \
             the fields.")
  and secret =
    Arg.(
      value & opt_all string []
      & info ["secret-field"] ~docv:"NAME"
          ~doc:
            "A secret custom field, its value asked without echo; repeat for \
             several.")
  in
  Term.(const (fun plain secret -> (plain, secret)) $ plain $ secret)

let fields_json (plain, secret) =
  if plain = [] && secret = [] then []
  else (
    let field ~secret name value =
      `Assoc [("name", s name); ("value", s value); ("secret", `Bool secret)]
    in
    [
      ( "fields",
        `List
          (List.map
             (fun nv ->
               match String.index_opt nv '=' with
                 | Some i ->
                     field ~secret:false (String.sub nv 0 i)
                       (String.sub nv (i + 1) (String.length nv - i - 1))
                 | None -> Fail.invalid "a field is NAME=VALUE, not %s" nv)
             plain
          @ List.map
              (fun name ->
                field ~secret:true name
                  (Vault_cmds.read_passphrase ~prompt:name ~stdin:false ()))
              secret) );
    ])

let optional fields =
  List.filter_map (fun (k, v) -> Option.map (fun v -> (k, s v)) v) fields

let add_cmd =
  verb "add" ~doc:"Add a login, or a note with --note."
    Term.(
      const
        (fun
          title
          note
          urls
          username
          password
          generate
          no_symbols
          notes
          otpauth
          totp
          fields
          ?name
          config
        ->
          let d = write_domain ?name config in
          let reply =
            call d "add"
              ((if note then [("kind", s "note"); ("title", s title)]
                else
                  [("title", s title); ("urls", `List (List.map s urls))]
                  @ secret_args ~no_symbols ~ask_if_absent:true
                      (secret_of ~password ~generate))
              @ fields_json fields
              @ optional
                  [
                    ("username", username);
                    ("notes", notes);
                    ("otpauth", Option.map from_stdin otpauth);
                    ("totp", totp);
                  ])
          in
          say "%s %s" (dname d)
            (Option.value ~default:"" (field (`Assoc reply) "id"));
          0)
      $ Arg.(
          required
          & opt (some string) None
          & info ["title"] ~docv:"TEXT" ~doc:"The login's title.")
      $ Arg.(
          value & flag
          & info ["note"]
              ~doc:
                "A note (§2.1): a title, notes and fields, with no site or \
                 password.")
      $ urls_arg
      $ opt_string "username" ~doc:"The username."
      $ password_arg $ generate_arg $ no_symbols
      $ opt_string "notes" ~doc:"Notes."
      $ opt_string "otpauth"
          ~doc:
            "An otpauth://totp/ URI to add and link; - reads it from standard \
             input."
      $ opt_string "totp" ~doc:"A TOTP record id to link, or empty to unlink."
      $ fields_arg)

let list_cmd =
  verb "list" ~doc:"List logins and passkeys; no password."
    Term.(
      const (fun filter site ?name config ->
          List.iter
            (fun (d, reply) ->
              List.iter
                (fun row ->
                  let f k = Option.value ~default:"" (field row k) in
                  if f "kind" = "login" then
                    say "%s %s login %s %s %s" (dname d) (f "id") (f "title")
                      (f "username")
                      (match member row "dangling" with
                        | Some (`Bool true) -> "(code link dangling)"
                        | _ -> (
                            match member row "code" with
                              | Some (`Bool true) -> "(code)"
                              | _ -> ""))
                  else if f "kind" = "note" then
                    say "%s %s note %s" (dname d) (f "id") (f "title")
                  else
                    say "%s %s passkey %s %s" (dname d) (f "id") (f "rpId")
                      (f "userName"))
                (records reply))
            (each ?name config (fun d ->
                 call d "list" (optional [("filter", filter); ("site", site)])));
          0)
      $ opt_string "filter"
          ~doc:"Only records whose title, username or sites contain TEXT."
      $ opt_string "site" ~doc:"Only records matching the site TEXT.")

let id_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"ID" ~doc:"The record's id.")

let get_cmd =
  verb "get"
    ~doc:
      "Print a login's password alone, newline-terminated, a note's notes, a \
       field's value with --field, or a passkey's fields."
    Term.(
      const (fun id wanted ?name config ->
          let reply = call (holder ?name config id) "get" [("id", s id)] in
          let f k = Option.value ~default:"" (field (`Assoc reply) k) in
          match wanted with
            | Some wanted -> (
                let value =
                  match member (`Assoc reply) "fields" with
                    | Some (`List l) ->
                        List.find_map
                          (fun j ->
                            if field j "name" = Some wanted then field j "value"
                            else None)
                          l
                    | _ -> None
                in
                match value with
                  | Some v ->
                      print_endline v;
                      0
                  | None -> Fail.absent "no field %s" wanted)
            | None ->
                if f "kind" = "login" then print_endline (f "password")
                else if f "kind" = "note" then print_endline (f "notes")
                else
                  List.iter
                    (fun k -> say "%s %s" k (f k))
                    [
                      "rpId";
                      "userName";
                      "userDisplayName";
                      "credentialId";
                      "login";
                    ];
                0)
      $ id_arg
      $ opt_string "field" ~doc:"Print the value of the field NAME instead.")

let generate_cmd =
  verb "generate"
    ~doc:"Print a generated password, 20 characters unless told otherwise (§5)."
    Term.(
      const (fun (length, words) no_symbols ?name config ->
          let d = write_domain ?name config in
          let how =
            match (length, words) with
              | Some _, Some _ ->
                  Fail.invalid "give --generate or --words, not both"
              | _, Some n -> `Words n
              | Some n, None -> `Length n
              | None, None -> `Length 20
          in
          say "%s"
            (Option.value ~default:""
               (field
                  (`Assoc
                     (call d "generate"
                        [("generate", generate_json ~no_symbols how)]))
                  "password"));
          0)
      $ generate_arg $ no_symbols)

let edit_cmd =
  verb "edit" ~doc:"Change a login's fields, or a passkey's login."
    Term.(
      const
        (fun
          id
          title
          urls
          username
          password
          generate
          no_symbols
          notes
          otpauth
          totp
          login
          fields
          ?name
          config
        ->
          ignore
            (call (holder ?name config id) "edit"
               ([("id", s id)]
               @ (if urls = [] then [] else [("urls", `List (List.map s urls))])
               @ secret_args ~no_symbols ~ask_if_absent:false
                   (secret_of ~password ~generate)
               @ fields_json fields
               @ optional
                   [
                     ("title", title);
                     ("username", username);
                     ("notes", notes);
                     ("otpauth", Option.map from_stdin otpauth);
                     ("totp", totp);
                     ("login", login);
                   ]));
          0)
      $ id_arg
      $ opt_string "title" ~doc:"The title."
      $ urls_arg
      $ opt_string "username" ~doc:"The username."
      $ password_arg $ generate_arg $ no_symbols
      $ opt_string "notes" ~doc:"Notes."
      $ opt_string "otpauth" ~doc:"An otpauth://totp/ URI to add and link."
      $ opt_string "totp" ~doc:"A TOTP record id to link, or empty to unlink."
      $ opt_string "login" ~doc:"For a passkey: the login it belongs with."
      $ fields_arg)

let remove_cmd =
  verb "remove" ~doc:"Remove a login or a passkey."
    Term.(
      const (fun id ?name config ->
          ignore (call (holder ?name config id) "remove" [("id", s id)]);
          0)
      $ id_arg)

let import_cmd =
  verb "import" ~doc:"Add one login per row of a CSV export (§10.1)."
    Term.(
      const (fun file ?name config ->
          let text = In_channel.with_open_bin file In_channel.input_all in
          let reply =
            call (write_domain ?name config) "import" [("text", s text)]
          in
          let j = `Assoc reply in
          say "added %s" (Yojson.Safe.to_string (Option.get (member j "added")));
          (match member j "skipped" with
            | Some (`List rows) ->
                List.iter
                  (fun r ->
                    prerr_endline
                      (Printf.sprintf "tsync: line %s skipped: %s"
                         (Yojson.Safe.to_string (Option.get (member r "line")))
                         (Option.value ~default:"" (field r "reason"))))
                  rows
            | _ -> ());
          say "seeds added %s, dropped %s"
            (Yojson.Safe.to_string (Option.get (member j "seedsAdded")))
            (Yojson.Safe.to_string (Option.get (member j "seedsDropped")));
          0)
      $ Arg.(
          required
          & pos 0 (some file) None
          & info [] ~docv:"FILE" ~doc:"The CSV file."))

let export_cmd =
  verb "export"
    ~doc:
      "Print every login as CSV; asks each domain's passphrase. Passkeys are \
       not exported."
    Term.(
      const (fun stdin ?name config ->
          List.iter
            (fun (d, reply) ->
              print_string
                (Option.value ~default:"" (field (`Assoc reply) "csv"));
              match List.assoc_opt "passkeys" reply with
                | Some (`Int n) when n > 0 ->
                    prerr_endline
                      (Printf.sprintf "tsync: %s: %d passkeys are not exported"
                         (dname d) n)
                | _ -> ())
            (each ?name config (fun d ->
                 let passphrase =
                   Vault_cmds.read_passphrase
                     ~prompt:(Printf.sprintf "passphrase of %s" (dname d))
                     ~stdin ()
                 in
                 call d "export" [("passphrase", s passphrase)]));
          0)
      $ Arg.(
          value & flag
          & info ["stdin"] ~doc:"Read each passphrase from standard input."))

(* §9.1: a 32-bit length in this host's byte order, then that much UTF-8 JSON. *)
let max_message = 1 lsl 20

let read_message ic =
  let header = Bytes.create 4 in
  match really_input ic header 0 4 with
    | () ->
        let n = Int32.to_int (Bytes.get_int32_ne header 0) in
        if n < 0 || n > max_message then None
        else Some (really_input_string ic n)
    | exception End_of_file -> None

let write_message oc json =
  let body = Yojson.Safe.to_string json in
  let body =
    if String.length body > max_message then
      {|{"ok":false,"code":"internal","error":"the answer is too large"}|}
    else body
  in
  let header = Bytes.create 4 in
  Bytes.set_int32_ne header 0 (Int32.of_int (String.length body));
  output_bytes oc header;
  output_string oc body;
  flush oc

let str j k = match member j k with Some (`String v) -> Some v | _ -> None

let required j k =
  match str j k with Some v -> v | None -> Fail.invalid "%s is missing" k

let fields_of j = match j with `Assoc l -> l | _ -> []

(* The members of a request a verb takes; the rest are dropped. *)
let only j keys = List.filter (fun (k, _) -> List.mem k keys) (fields_of j)

(* §9.2 verify: set by a platform verification, spent by the session's next
   passkey request. *)
type session = { mutable verified : bool }

let verified_once session =
  if session.verified then (
    session.verified <- false;
    [("verified", `Bool true)])
  else []

(* §9.2: every domain using passwords, each answering on its own. *)
let bridge_request config session j =
  let all f =
    List.map
      (fun (d : Config.domain) -> (d, try Ok (f d) with Fail.E e -> Error e))
      (using ~extension config)
  in
  let pick j =
    match str j "domain" with
      | Some n -> Cli.domain ~name:n config
      | None -> write_domain config
  in
  match str j "type" with
    | Some "status" ->
        [
          (* browser §5: without one, the extension asks the passphrase. *)
          ( "verifier",
            match Tsync_owner.Verifier.registered () with
              | Some v -> `String v.name
              | None -> `Null );
          ( "domains",
            `List
              (List.map
                 (fun (d, r) ->
                   `Assoc
                     ([
                        ("domain", s (dname d));
                        ( "state",
                          s
                            (match r with
                              | Ok (st : P.vault_status) -> (
                                  match st.vault with
                                    | `Unlocked -> "unlocked"
                                    | `Locked -> "locked"
                                    | `Absent -> "absent"
                                    | `Corrupt _ -> "corrupt")
                              | Error (e : Fail.t) -> Fail.code e.kind) );
                      ]
                     (* vault §8.1: how the extension draws the domain's rows. *)
                     @
                       match r with
                       | Ok { appearance = Some a; _ } ->
                           [
                             ( "appearance",
                               `Assoc
                                 (("color", s a.color)
                                 ::
                                   (match a.icon with
                                   | Some png ->
                                       [("icon", s (Base64.encode_string png))]
                                   | None -> [])) );
                           ]
                       | _ -> []))
                 (all (fun d -> Vault_cmds.ask d (P.Vault_status `Auto)))) );
        ]
    | Some "match" ->
        let origin = required j "origin" in
        let answers = all (fun d -> call d "list" [("site", s origin)]) in
        [
          ( "logins",
            `List
              (List.concat_map
                 (fun (d, r) ->
                   match r with
                     | Ok reply ->
                         List.filter_map
                           (fun row ->
                             if field row "kind" <> Some "login" then None
                             else
                               Some
                                 (`Assoc
                                    [
                                      ("domain", s (dname d));
                                      ("id", Option.get (member row "id"));
                                      ("title", Option.get (member row "title"));
                                      ( "username",
                                        Option.get (member row "username") );
                                      ("code", Option.get (member row "code"));
                                      (* browser §3.2: whether the login is for
                                         this origin itself, not by suffix. *)
                                      ( "exact",
                                        `Bool
                                          (match
                                             Passwords.site_of_string origin
                                           with
                                            | Ok site ->
                                                List.mem (`String site)
                                                  (match member row "urls" with
                                                    | Some (`List l) -> l
                                                    | _ -> [])
                                            | Error _ -> false) );
                                    ]))
                           (records reply)
                     | Error _ -> [])
                 answers) );
          ( "locked",
            `List
              (List.filter_map
                 (fun (d, r) ->
                   match r with
                     | Error (e : Fail.t) when e.kind = Locked ->
                         Some (s (dname d))
                     | _ -> None)
                 answers) );
        ]
    (* §9.2: the owner's passwords_fill and passwords_save, which a page's
       origin names the site of. *)
    | Some "fill" ->
        call (pick j) "fill"
          [("site", s (required j "origin")); ("id", s (required j "id"))]
    | Some "save" ->
        call (pick j) "save"
          ([
             ("site", s (required j "origin"));
             ("username", s (required j "username"));
           ]
          @ (match str j "suggested" with
            | Some id -> [("suggested", s id)]
            | None -> [("password", s (required j "password"))])
          @
            match str j "update" with
            | Some id -> [("update", s id)]
            | None -> [])
    (* passwords §5.1: the reply names the domain the login went to, which the
       submit's save names again. *)
    | Some "suggest" ->
        let d = pick j in
        ("domain", s (dname d))
        :: call d "suggest"
             [
               ("site", s (required j "origin"));
               ("username", s (Option.value ~default:"" (str j "username")));
             ]
    | Some "passkey_match" ->
        let answers =
          all (fun d ->
              call d "passkey_match" (only j ["origin"; "rpId"; "allow"]))
        in
        [
          ( "passkeys",
            `List
              (List.concat_map
                 (fun (_, r) ->
                   match r with
                     | Ok reply -> (
                         match List.assoc_opt "passkeys" reply with
                           | Some (`List l) -> l
                           | _ -> [])
                     | Error _ -> [])
                 answers) );
          (* browser §5: a locked domain is said, not passed over. *)
          ( "locked",
            `List
              (List.filter_map
                 (fun (d, r) ->
                   match r with
                     | Error (e : Fail.t) when e.kind = Locked ->
                         Some (s (dname d))
                     | _ -> None)
                 answers) );
        ]
    (* §9.2 verify: the platform's own verifier; the prompt names the origin
       the browser gave, never a page's words. *)
    | Some "verify" -> (
        match Tsync_owner.Verifier.registered () with
          | None ->
              Fail.invalid
                "this machine has no verifier: the passphrase verifies"
          | Some verifier -> (
              let reason = "use a passkey on " ^ required j "origin" in
              match verifier.verify ~reason with
                | Ok () ->
                    session.verified <- true;
                    [("verified", `Bool true)]
                | Error why -> Fail.raise_ Denied "%s: %s" verifier.name why))
    (* §7.4: a browser verifies with the passphrase, or through [verify]; a
       [verified] it sends never reaches the owner. *)
    | Some "passkey_create" ->
        call (pick j) "passkey_create"
          (verified_once session
          @ only j
              [
                "origin";
                "rpId";
                "userHandle";
                "userName";
                "userDisplayName";
                "algorithms";
                "exclude";
                "clientDataHash";
                "passphrase";
                "login";
              ])
    | Some "passkey_assert" ->
        call (pick j) "passkey_assert"
          (verified_once session
          @ only j ["origin"; "rpId"; "id"; "clientDataHash"; "passphrase"])
    | Some other -> Fail.invalid "the bridge does not forward %s" other
    | None -> Fail.invalid "a request names its type"

let browser_host_cmd =
  Cli.cmd "browser-host"
    ~doc:
      "The native-messaging bridge a browser starts (§9.1); not for a terminal."
    Term.(
      const (fun _origin ->
          set_binary_mode_in stdin true;
          set_binary_mode_out stdout true;
          Cli.run @@ fun () ->
          let config = Cli.config () in
          let session = { verified = false } in
          let rec serve () =
            match read_message stdin with
              | None -> 0
              | Some text ->
                  let reply =
                    match Yojson.Safe.from_string text with
                      | j -> (
                          match bridge_request config session j with
                            | fields -> `Assoc (("ok", `Bool true) :: fields)
                            | exception Fail.E e -> Tsync_ipc.Ipc.failure e)
                      | exception Yojson.Json_error _ ->
                          Tsync_ipc.Ipc.failure (Fail.make Invalid "not JSON")
                  in
                  write_message stdout reply;
                  serve ()
          in
          serve ())
      (* Chromium passes the caller's origin; Firefox the manifest path. *)
      $ Arg.(value & pos_all string [] & info [] ~docv:"ARGS"))

(* browser §2: the extension's id, fixed by the public key its manifest
   carries. *)
let extension_id = "cdnflbhllfjagecmodmfhaidolcjlpga"
let host_name = "org.feverdreamtv.tsync"

(* The per-user directories of the Chromium-family browsers, by host. *)
let browser_dirs () =
  let home = Sys.getenv "HOME" in
  if Sys.file_exists "/System/Library/CoreServices/SystemVersion.plist" then
    List.map
      (Filename.concat (Filename.concat home "Library/Application Support"))
      [
        "Google/Chrome";
        "Google/Chrome Beta";
        "Chromium";
        "BraveSoftware/Brave-Browser";
        "Microsoft Edge";
        "Vivaldi";
      ]
  else (
    let config =
      match Sys.getenv_opt "XDG_CONFIG_HOME" with
        | Some d when d <> "" -> d
        | _ -> Filename.concat home ".config"
    in
    List.map (Filename.concat config)
      [
        "google-chrome";
        "google-chrome-beta";
        "chromium";
        "BraveSoftware/Brave-Browser";
        "microsoft-edge";
        "vivaldi";
      ])

(* A browser starts the host with arguments of its own: a script names this
   program by its resolved path. *)
let launcher () =
  let home = Sys.getenv "HOME" in
  let dir =
    if Sys.file_exists "/System/Library/CoreServices/SystemVersion.plist" then
      Filename.concat home "Library/Application Support/tsync"
    else
      Filename.concat
        (match Sys.getenv_opt "XDG_DATA_HOME" with
          | Some d when d <> "" -> d
          | _ -> Filename.concat home ".local/share")
        "tsync"
  in
  Filename.concat dir "browser-host"

let manifest_path dir =
  Filename.concat dir ("NativeMessagingHosts/" ^ host_name ^ ".json")

(* The outermost app bundle holding this program carries the extension; a
   Linux package puts it under /usr/share. *)
let extension_dir program =
  let parts = String.split_on_char '/' program in
  let rec bundle acc = function
    | [] -> None
    | p :: _ when Filename.check_suffix p ".app" ->
        Some (String.concat "/" (List.rev (p :: acc)))
    | p :: rest -> bundle (p :: acc) rest
  in
  let candidates =
    Option.to_list
      (Option.map
         (fun app -> Filename.concat app "Contents/Resources/browser-extension")
         (bundle [] parts))
    @ ["/usr/share/tsync/browser-extension"]
  in
  List.find_opt Sys.file_exists candidates

let browser_install ids =
  List.iter
    (fun id ->
      if
        String.length id <> 32
        || not (String.for_all (function 'a' .. 'p' -> true | _ -> false) id)
      then Fail.invalid "%s is not an extension id: 32 letters a to p" id)
    ids;
  let program = Unix.realpath Sys.executable_name in
  let script = launcher () in
  Fs.mkdir_p (Filename.dirname script);
  Fs.replace ~perm:0o755 script
    (Printf.sprintf "#!/bin/sh\nexec %s passwords browser-host \"$@\"\n"
       (Filename.quote program));
  let manifest =
    Yojson.Safe.pretty_to_string
      (`Assoc
         [
           ("name", `String host_name);
           ("description", `String "tsync passwords");
           ("path", `String script);
           ("type", `String "stdio");
           ( "allowed_origins",
             `List
               (List.map
                  (fun id -> `String ("chrome-extension://" ^ id ^ "/"))
                  (extension_id :: ids)) );
         ])
  in
  let installed =
    List.filter_map
      (fun dir ->
        if not (Sys.file_exists dir) then None
        else (
          let path = manifest_path dir in
          Fs.mkdir_p (Filename.dirname path);
          Fs.replace ~perm:0o644 path (manifest ^ "\n");
          Some path))
      (browser_dirs ())
  in
  if installed = [] then say "No Chromium-family browser found for this user."
  else List.iter (say "installed %s") installed;
  (* browser §2: a browser's folder picker cannot open a folder inside an app
     bundle, so the extension is copied next to the launcher, replaced whole. *)
    match extension_dir program with
    | Some source ->
        let dir =
          Filename.concat (Filename.dirname script) "browser-extension"
        in
        Fs.rm_rf dir;
        if
          Sys.command
            (Printf.sprintf "cp -R %s %s" (Filename.quote source)
               (Filename.quote dir))
          <> 0
        then Fail.raise_ Refused "could not copy the extension to %s" dir;
        say
          "To add the extension: open chrome://extensions, turn on Developer \
           mode, choose Load unpacked, and pick %s"
          dir
    | None -> ()

let browser_uninstall () =
  List.iter
    (fun dir ->
      let path = manifest_path dir in
      if Sys.file_exists path then (
        Sys.remove path;
        say "removed %s" path))
    (browser_dirs ());
  if Sys.file_exists (launcher ()) then Sys.remove (launcher ())

let browser_cmd =
  let ids =
    Arg.(
      value & opt_all string []
      & info ["extension-id"] ~docv:"ID"
          ~doc:"Also allow the extension with this id; repeat for several.")
  in
  Cmd.group
    (Cmd.info "browser"
       ~doc:"The browser extension's native-messaging host (browser §2).")
    [
      Cli.cmd "install"
        ~doc:
          "Let the browsers of this user start the bridge for tsync's \
           extension."
        Term.(
          const (fun ids ->
              Cli.run @@ fun () ->
              browser_install ids;
              0)
          $ ids);
      Cli.cmd "uninstall" ~doc:"Remove what install wrote."
        Term.(
          const (fun () ->
              Cli.run @@ fun () ->
              browser_uninstall ();
              0)
          $ const ());
    ]

let cmds =
  [
    Cmd.group
      (Cmd.info "passwords"
         ~doc:"Logins and passkeys kept in the domain's vault.")
      [
        add_cmd;
        list_cmd;
        get_cmd;
        edit_cmd;
        generate_cmd;
        remove_cmd;
        import_cmd;
        export_cmd;
        browser_host_cmd;
        browser_cmd;
      ];
  ]
