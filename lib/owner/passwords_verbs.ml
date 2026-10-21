(* The passwords extension's verbs (spec extensions/passwords §5–§7, §10): logins
   and passkeys, through the generic extension request. *)
open Tsync_core
module Passwords = Tsync_vault.Passwords
module Webauthn = Tsync_vault.Webauthn
module Totp = Tsync_vault.Totp

include Extension_records.Make (struct
  type t = Passwords.t

  let name = "passwords"
  let of_string = Passwords.of_string
  let to_string = Passwords.to_string
  let key_fields = Passwords.key_fields
  let modified = Passwords.modified

  (* §2, §7.1: a label is at most 256 bytes, so the suffix replaces the label's
     end where both do not fit, cut at a UTF-8 boundary. *)
  let fit label suffix =
    let room = 256 - String.length suffix in
    let rec cut n =
      if n <= 0 then 0
      else if n >= String.length label then String.length label
      else if Char.code label.[n] land 0xC0 = 0x80 then cut (n - 1)
      else n
    in
    String.sub label 0 (cut room) ^ suffix

  (* totp §3, as this extension labels: a login's or a note's title, a
     passkey's display name. *)
  let relabel ~suffix = function
    | Passwords.Login l when not (String.ends_with ~suffix l.title) ->
        Some (Passwords.Login { l with title = fit l.title suffix })
    | Note n when not (String.ends_with ~suffix n.title) ->
        Some (Note { n with title = fit n.title suffix })
    | Passkey p when not (String.ends_with ~suffix p.user_display_name) ->
        let shown =
          if p.user_display_name = "" then p.user_name else p.user_display_name
        in
        Some (Passkey { p with user_display_name = fit shown suffix })
    | _ -> None
end)

let arg args k = List.assoc_opt k args

(* android §3.2 rule 1, for a read: a host with a deadline asks for
   [background]. *)
let pull_of args : Protocol.pull =
  match List.assoc_opt "pull" args with
    | Some (`String "background") -> `Background
    | Some (`String "now") -> `Now
    | Some (`String "never") -> `Never
    | None | Some (`String "auto") -> `Auto
    | Some _ -> Fail.invalid "unknown pull"

let str args k =
  match arg args k with
    | Some (`String s) -> Some s
    | None | Some `Null -> None
    | Some _ -> Fail.invalid "%s must be a string" k

let required args k =
  match str args k with Some s -> s | None -> Fail.invalid "%s is missing" k

let strings args k =
  match arg args k with
    | None | Some `Null -> None
    | Some (`List l) ->
        Some
          (List.map
             (function
               | `String s -> s | _ -> Fail.invalid "%s must hold strings" k)
             l)
    | Some _ -> Fail.invalid "%s must be a list" k

let ints args k =
  match arg args k with
    | Some (`List l) ->
        List.map
          (function `Int i -> i | _ -> Fail.invalid "%s must hold integers" k)
          l
    | _ -> Fail.invalid "%s is missing" k

let flag args k = match arg args k with Some (`Bool b) -> b | _ -> false
let b64 s = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let unb64 k s =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s with
    | Ok v -> v
    | Error _ -> Fail.invalid "%s is not base64url" k

(* §2: a record is written only as it reads back. *)
let checked record =
  match Passwords.of_string (Passwords.to_string record) with
    | Ok r -> r
    | Error reason -> Fail.invalid "%s" reason

let sites args =
  List.map
    (fun s ->
      match Passwords.site_of_string s with
        | Ok site -> site
        | Error reason -> Fail.invalid "%s" reason)
    (Option.value ~default:[] (strings args "urls"))

(* §5: [length] and [symbols], or [words]. *)
let generated g =
  let g = match g with `Assoc l -> l | _ -> [] in
  match (arg g "words", arg g "length") with
    | Some (`Int n), None ->
        if n < 4 || n > 12 then Fail.invalid "words is 4 to 12"
        else Tsync_vault.Words.passphrase n
    | Some _, None -> Fail.invalid "words is a number, 4 to 12"
    | Some _, Some _ -> Fail.invalid "give words or length, not both"
    | None, length -> (
        let length = match length with Some (`Int n) -> n | _ -> 20
        and symbols =
          match arg g "symbols" with Some (`Bool b) -> b | _ -> true
        in
        match Passwords.generate ~length ~symbols with
          | Ok p -> p
          | Error reason -> Fail.invalid "%s" reason)

(* §5: the password given, else one generated. *)
let password_of args =
  match (str args "password", arg args "generate") with
    | Some p, None -> Some p
    | None, Some g -> Some (generated g)
    | None, None -> None
    | Some _, Some _ -> Fail.invalid "give a password or generate, not both"

let uses_totp ~domain ~engine =
  List.mem "totp" (Vault.extensions ~domain ~engine)

(* §6: the TOTP record a login names, from [otpauth] (added) or [totp] (an
   existing id, or empty to unlink); [None] when neither is given. *)
let link ~domain ~engine ~lazy_tree t args =
  let needs_totp () =
    if not (uses_totp ~domain ~engine) then
      Fail.invalid "%s does not use totp: a login cannot link a code"
        (Domain_name.to_string domain.Tsync_domain.Domain.name)
  in
  match (str args "otpauth", str args "totp") with
    | Some uri, None ->
        needs_totp ();
        Some (Totp_verbs.add ~domain ~engine ~lazy_tree t (`Uri uri))
    | None, Some "" -> Some ""
    | None, Some id ->
        needs_totp ();
        let ctx = Totp_verbs.context ~domain ~engine ~lazy_tree t in
        ignore (Totp_verbs.find ctx id);
        Some id
    | None, None -> None
    | Some _, Some _ -> Fail.invalid "give otpauth or totp, not both"

(* §2.2: a field list as given, every entry checked with the record. *)
let fields_arg args =
  match arg args "fields" with
    | None -> []
    | Some (`List l) ->
        List.map
          (function
            | `Assoc f -> (
                match (arg f "name", arg f "value", arg f "secret") with
                  | Some (`String name), Some (`String value), secret ->
                      {
                        Passwords.name;
                        value;
                        secret =
                          (match secret with Some (`Bool b) -> b | _ -> false);
                      }
                  | _ -> Fail.invalid "a field is {name, value, secret}")
            | _ -> Fail.invalid "a field is {name, value, secret}")
          l
    | Some _ -> Fail.invalid "fields is a list"

let fields_json (fields : Passwords.field list) =
  `List
    (List.map
       (fun (f : Passwords.field) ->
         `Assoc
           [
             ("name", `String f.name);
             ("value", `String f.value);
             ("secret", `Bool f.secret);
           ])
       fields)

(* §2.1: a note has no site, password or code. *)
let add_note ~domain ~engine ~lazy_tree t args =
  let ctx = context ~writing:true ~domain ~engine ~lazy_tree t in
  List.iter
    (fun k -> if arg args k <> None then Fail.invalid "a note has no %s" k)
    ["urls"; "username"; "password"; "generate"; "otpauth"; "totp"];
  let record =
    checked
      (Note
         {
           title = required args "title";
           notes = Option.value ~default:"" (str args "notes");
           fields = fields_arg args;
           modified = now ();
           unknown = [];
         })
  in
  let id = Ids.token () in
  write ctx ~exclusive:true id record;
  [("id", `String id)]

let add ~domain ~engine ~lazy_tree t args =
  if str args "kind" = Some "note" then
    add_note ~domain ~engine ~lazy_tree t args
  else (
    let ctx = context ~writing:true ~domain ~engine ~lazy_tree t in
    let password =
      match password_of args with
        | Some p -> p
        | None -> Fail.invalid "a password or generate is needed"
    in
    let login : Passwords.login =
      {
        title = required args "title";
        urls = sites args;
        username = Option.value ~default:"" (str args "username");
        password;
        notes = Option.value ~default:"" (str args "notes");
        totp = "";
        fields = fields_arg args;
        modified = now ();
        unknown = [];
      }
    in
    (* §6: the login is checked before a TOTP record is added for it. *)
    ignore (checked (Login login));
    let record =
      checked
        (Login
           {
             login with
             totp =
               Option.value ~default:"" (link ~domain ~engine ~lazy_tree t args);
           })
    in
    let id = Ids.token () in
    write ctx ~exclusive:true id record;
    [("id", `String id)])

let logins records =
  List.filter_map
    (function id, Passwords.Login l -> Some (id, l) | _ -> None)
    records

let passkeys records =
  List.filter_map
    (function id, Passwords.Passkey p -> Some (id, p) | _ -> None)
    records

let contains ~sub s =
  Text.contains (String.lowercase_ascii s) (String.lowercase_ascii sub)

(* §6: the TOTP record ids present, read once per verb; [None] when the domain
   does not use totp. *)
let totp_ids ?use ?pull ~domain ~engine ~lazy_tree t =
  if not (uses_totp ~domain ~engine) then None
  else (
    let ctx = Totp_verbs.context ?use ?pull ~domain ~engine ~lazy_tree t in
    let ok, corrupt = Totp_verbs.records ctx in
    Some (List.map fst ok @ corrupt))

(* §6: a link to a TOTP record that is gone. *)
let dangling ids totp =
  totp <> ""
  && match ids with Some ids -> not (List.mem totp ids) | None -> false

(* §10 list: logins, then passkeys, each ordered by title then username then
   id. *)
let list ~domain ~engine ~lazy_tree t args =
  (* vault §6.2: a host's refresh in the background is no use of the vault. *)
  let use = arg args "use" <> Some (`Bool false) in
  let ctx = context ~use ~pull:(pull_of args) ~domain ~engine ~lazy_tree t in
  let ok, corrupt = records ctx in
  (* The rows' code lookups read the TOTP folder, which sets the view again. *)
  let records_view = Atomic.get t.Vault.view in
  let filter = str args "filter" and site = str args "site" in
  let shown_login (l : Passwords.login) =
    (match filter with
      | Some sub ->
          contains ~sub l.title || contains ~sub l.username
          || List.exists (contains ~sub) l.urls
      | None -> true)
    &&
      match site with
      | Some origin ->
          List.exists (fun s -> Passwords.matches ~site:s ~origin) l.urls
      | None -> true
  in
  let rp_of_site origin =
    match Passwords.site_of_string origin with
      | Ok site -> Passwords.host_of site
      | Error _ -> origin
  in
  let shown_passkey (p : Passwords.passkey) =
    (match filter with
      | Some sub -> contains ~sub p.rp_id || contains ~sub p.user_name
      | None -> true)
    &&
      match site with
      | Some origin ->
          let host = rp_of_site origin in
          host = p.rp_id || String.ends_with ~suffix:("." ^ p.rp_id) host
      | None -> true
  in
  let keys = passkeys ok in
  let ids = totp_ids ~use ~pull:(pull_of args) ~domain ~engine ~lazy_tree t in
  (* §2.1: a note matches no site; it is listed by title alone. *)
  let note_rows =
    if site <> None then []
    else
      List.filter_map
        (function
          | id, Passwords.Note n
            when match filter with
                   | Some sub -> contains ~sub n.title
                   | None -> true ->
              Some (n.title, id)
          | _ -> None)
        ok
      |> List.sort compare
      |> List.map (fun (title, id) ->
          `Assoc
            [
              ("id", `String id);
              ("kind", `String "note");
              ("title", `String title);
            ])
  in
  (* §4.2: the request's own host first. *)
  let on_host (l : Passwords.login) =
    match site with
      | Some origin ->
          let host = rp_of_site origin in
          List.exists (fun u -> Passwords.host_of u = host) l.urls
      | None -> false
  in
  let login_rows =
    logins ok
    |> List.filter (fun (_, l) -> shown_login l)
    |> List.sort (fun (a, (x : Passwords.login)) (b, (y : Passwords.login)) ->
        compare
          (not (on_host x), x.title, x.username, a)
          (not (on_host y), y.title, y.username, b))
    |> List.map (fun (id, (l : Passwords.login)) ->
        `Assoc
          [
            ("id", `String id);
            ("kind", `String "login");
            ("title", `String l.title);
            ("username", `String l.username);
            ("urls", `List (List.map (fun u -> `String u) l.urls));
            ("code", `Bool (l.totp <> ""));
            ("dangling", `Bool (dangling ids l.totp));
            ( "passkeys",
              `List
                (List.filter_map
                   (fun (pid, (p : Passwords.passkey)) ->
                     if p.login = id then Some (`String pid) else None)
                   keys) );
          ])
  in
  let passkey_rows =
    keys
    |> List.filter (fun (_, p) -> shown_passkey p)
    |> List.sort
         (fun (a, (x : Passwords.passkey)) (b, (y : Passwords.passkey)) ->
           compare (x.rp_id, x.user_name, a) (y.rp_id, y.user_name, b))
    |> List.map (fun (id, (p : Passwords.passkey)) ->
        `Assoc
          [
            ("id", `String id);
            ("kind", `String "passkey");
            ("rpId", `String p.rp_id);
            ("userName", `String p.user_name);
            ("credentialId", `String (b64 p.credential_id));
            ("userHandle", `String (b64 p.user_handle));
            ("login", `String p.login);
          ])
  in
  let view = Atomic.get t.Vault.view in
  let view = { view with outdated = view.outdated || records_view.outdated } in
  [
    ("records", `List (login_rows @ note_rows @ passkey_rows));
    ("corrupt", `List (List.map (fun c -> `String c) corrupt));
  ]
  @ (if view.outdated then [("outdated", `Bool true)] else [])
  @
    match view.pulled_at with
    | Some at -> [("pulledAt", `Int (int_of_float at))]
    | None -> []

let code ?pull ~domain ~engine ~lazy_tree t totp =
  if totp = "" || not (uses_totp ~domain ~engine) then []
  else (
    match Totp_verbs.code ?pull ~domain ~engine ~lazy_tree t totp with
      | c -> [("code", `String c.code); ("secondsLeft", `Int c.seconds_left)]
      | exception Fail.E { kind = Absent; _ } -> [("dangling", `Bool true)])

(* §10: the only reply with a password; never a private key. *)
let get ~domain ~engine ~lazy_tree t args =
  let ctx = context ~pull:(pull_of args) ~domain ~engine ~lazy_tree t in
  let id = required args "id" in
  match find ctx id with
    | Login l ->
        [
          ("kind", `String "login");
          ("title", `String l.title);
          ("username", `String l.username);
          ("urls", `List (List.map (fun u -> `String u) l.urls));
          ("password", `String l.password);
          ("notes", `String l.notes);
          ("totp", `String l.totp);
          ("fields", fields_json l.fields);
        ]
        @ code ~pull:(pull_of args) ~domain ~engine ~lazy_tree t l.totp
    | Note n ->
        [
          ("kind", `String "note");
          ("title", `String n.title);
          ("notes", `String n.notes);
          ("fields", fields_json n.fields);
        ]
    | Passkey p ->
        [
          ("kind", `String "passkey");
          ("rpId", `String p.rp_id);
          ("userName", `String p.user_name);
          ("userDisplayName", `String p.user_display_name);
          ("credentialId", `String (b64 p.credential_id));
          ("login", `String p.login);
        ]

let edit ~domain ~engine ~lazy_tree t args =
  let ctx = context ~writing:true ~domain ~engine ~lazy_tree t in
  let id = required args "id" in
  let given k f v = match arg args k with None -> v | Some _ -> f () in
  let record =
    match find ctx id with
      | Login l ->
          let edited : Passwords.login =
            {
              l with
              title = given "title" (fun () -> required args "title") l.title;
              urls = given "urls" (fun () -> sites args) l.urls;
              username =
                given "username" (fun () -> required args "username") l.username;
              password = Option.value ~default:l.password (password_of args);
              notes = given "notes" (fun () -> required args "notes") l.notes;
              fields = given "fields" (fun () -> fields_arg args) l.fields;
              modified = now ();
            }
          in
          (* §6: checked before a TOTP record is added for it. *)
          ignore (checked (Login edited));
          Passwords.Login
            {
              edited with
              totp =
                Option.value ~default:l.totp
                  (link ~domain ~engine ~lazy_tree t args);
            }
      | Note n ->
          if
            List.exists
              (fun (k, _) ->
                not (List.mem k ["id"; "title"; "notes"; "fields"]))
              args
          then
            Fail.invalid "a note's fields to edit are title, notes and fields";
          Note
            {
              n with
              title = given "title" (fun () -> required args "title") n.title;
              notes = given "notes" (fun () -> required args "notes") n.notes;
              fields = given "fields" (fun () -> fields_arg args) n.fields;
              modified = now ();
            }
      | Passkey p ->
          (* §7.1: a passkey's other fields are the relying party's. *)
          if List.exists (fun (k, _) -> k <> "id" && k <> "login") args then
            Fail.invalid "a passkey's only field to edit is its login";
          Passkey
            {
              p with
              login = given "login" (fun () -> required args "login") p.login;
              modified = now ();
            }
  in
  write ctx ~exclusive:false id (checked record);
  []

(* §10.1: rows added, rows skipped by line, seeds added and dropped. *)
let import ~domain ~engine ~lazy_tree t args =
  let ctx = context ~writing:true ~domain ~engine ~lazy_tree t in
  match Passwords.import_csv (required args "text") with
    | Error reason -> Fail.invalid "%s" reason
    | Ok (rows, skipped) ->
        let seeds_added = ref 0 and seeds_dropped = ref 0 and added = ref 0 in
        let skipped = ref skipped in
        List.iter
          (fun (row : Passwords.row) ->
            let totp =
              if row.otpauth = "" then ""
              else if not (uses_totp ~domain ~engine) then (
                incr seeds_dropped;
                "")
              else (
                match
                  Totp_verbs.add ~domain ~engine ~lazy_tree t (`Uri row.otpauth)
                with
                  | id ->
                      incr seeds_added;
                      id
                  | exception Fail.E _ ->
                      incr seeds_dropped;
                      "")
            in
            match
              checked
                (Login
                   {
                     title = row.title;
                     urls = row.urls;
                     username = row.username;
                     password = row.password;
                     notes = row.notes;
                     totp;
                     fields = [];
                     modified = now ();
                     unknown = [];
                   })
            with
              | record ->
                  write ctx ~exclusive:true (Ids.token ()) record;
                  incr added
              | exception Fail.E f ->
                  skipped := (row.line, f.reason) :: !skipped)
          rows;
        [
          ("added", `Int !added);
          ( "skipped",
            `List
              (List.map
                 (fun (line, reason) ->
                   `Assoc [("line", `Int line); ("reason", `String reason)])
                 (List.sort compare !skipped)) );
          ("seedsAdded", `Int !seeds_added);
          ("seedsDropped", `Int !seeds_dropped);
        ]

(* §10: the passphrase guards the export, as totp's; passkeys stay. *)
let export ~domain ~engine ~lazy_tree t args =
  let ctx = context ~domain ~engine ~lazy_tree t in
  Vault.confirm ~domain ~engine ~lazy_tree t (required args "passphrase");
  let ok, _ = records ctx in
  let totp_ctx =
    if uses_totp ~domain ~engine then
      Some (Totp_verbs.context ~domain ~engine ~lazy_tree t)
    else None
  in
  let otpauth (l : Passwords.login) =
    match totp_ctx with
      | Some c when l.totp <> "" -> (
          match Totp_verbs.find c l.totp with
            | r -> Totp.to_uri r
            | exception Fail.E _ -> "")
      | _ -> ""
  in
  let logins =
    logins ok
    |> List.sort (fun (a, (x : Passwords.login)) (b, (y : Passwords.login)) ->
        compare (x.title, x.username, a) (y.title, y.username, b))
    |> List.map snd
  in
  [
    ("csv", `String (Passwords.export_csv ~otpauth logins));
    ("passkeys", `Int (List.length (passkeys ok)));
  ]

(* rp ID to its related origins document and until when; a failed fetch keeps
   nothing, so the next request asks again. *)
let related : (string, string * float) Hashtbl.t = Hashtbl.create 8
let related_lock = Mutex.create ()

let related_document rp_id =
  let cached =
    Mutex.protect related_lock (fun () ->
        match Hashtbl.find_opt related rp_id with
          | Some (body, until) when until > Unix.gettimeofday () -> Some body
          | _ -> None)
  in
  match cached with
    | Some body -> Some body
    | None ->
        let body =
          (Atomic.get Well_known.fetch) rp_id "/.well-known/webauthn"
        in
        Option.iter
          (fun body ->
            Mutex.protect related_lock (fun () ->
                Hashtbl.replace related rp_id
                  (body, Unix.gettimeofday () +. 86400.)))
          body;
        body

let reset_related () =
  Mutex.protect related_lock (fun () -> Hashtbl.reset related)

(* §7.3: the RP ID belongs to the origin, or lists it as related. *)
let check_rp args =
  let origin = required args "origin" and rp_id = required args "rpId" in
  (match Webauthn.rp_id_allowed ~origin ~rp_id with
    | Ok () -> ()
    | Error reason ->
        let listed () =
          Webauthn.related_host rp_id
          && Option.fold ~none:false
               ~some:(Webauthn.related_allows ~origin)
               (related_document (String.lowercase_ascii rp_id))
        in
        if not (listed ()) then Fail.invalid "%s" reason);
  rp_id

(* §7.4: verified only on the passphrase, checked, or a host's word. *)
let user_verified ~domain ~engine ~lazy_tree t args =
  match str args "passphrase" with
    | Some passphrase ->
        Vault.confirm ~domain ~engine ~lazy_tree t passphrase;
        true
    | None -> flag args "verified"

let client_data_hash args =
  let h = unb64 "clientDataHash" (required args "clientDataHash") in
  if String.length h <> 32 then Fail.invalid "clientDataHash is 32 bytes";
  h

let passkey_create ~domain ~engine ~lazy_tree t args =
  let rp_id = check_rp args in
  if
    not
      (List.exists
         (fun a -> List.mem a Webauthn.supported)
         (ints args "algorithms"))
  then Fail.invalid "none of the algorithms is one this authenticator supports";
  ignore (client_data_hash args);
  let user_verified = user_verified ~domain ~engine ~lazy_tree t args in
  let ctx = context ~writing:true ~domain ~engine ~lazy_tree t in
  let exclude =
    List.map (unb64 "exclude")
      (Option.value ~default:[] (strings args "exclude"))
  in
  if
    List.exists
      (fun (_, (p : Passwords.passkey)) ->
        p.rp_id = rp_id && List.mem p.credential_id exclude)
      (passkeys (fst (records ctx)))
  then Fail.raise_ Exists "this authenticator holds an excluded credential";
  let private_key = Webauthn.generate_key () in
  let credential_id = Ids.urandom 32 in
  let record =
    checked
      (Passkey
         {
           rp_id;
           credential_id;
           user_handle = unb64 "userHandle" (required args "userHandle");
           user_name = Option.value ~default:"" (str args "userName");
           user_display_name =
             Option.value ~default:"" (str args "userDisplayName");
           algorithm = -7;
           private_key;
           login = Option.value ~default:"" (str args "login");
           created = now ();
           modified = now ();
           unknown = [];
         })
  in
  let id = Ids.token () in
  write ctx ~exclusive:true id record;
  let authenticator_data =
    Webauthn.authenticator_data
      ~attested:(credential_id, private_key)
      ~rp_id { user_verified } ()
  in
  [
    ("id", `String id);
    ("credentialId", `String (b64 credential_id));
    ( "attestationObject",
      `String (b64 (Webauthn.attestation_object ~authenticator_data)) );
    ("authenticatorData", `String (b64 authenticator_data));
    ("publicKey", `String (b64 (Webauthn.public_key_spki private_key)));
    ("algorithm", `Int (-7));
  ]

let passkey_match ~domain ~engine ~lazy_tree t args =
  let rp_id = check_rp args in
  (* §7.3: an empty allow-list is none. *)
  let allow =
    match strings args "allow" with
      | None | Some [] -> None
      | Some ids -> Some (List.map (unb64 "allow") ids)
  in
  let ctx = context ~pull:(pull_of args) ~domain ~engine ~lazy_tree t in
  let ok, _ = records ctx in
  let title id =
    match List.assoc_opt id (logins ok) with Some l -> l.title | None -> ""
  in
  [
    ( "passkeys",
      `List
        (List.filter_map
           (fun (id, (p : Passwords.passkey)) ->
             if
               p.rp_id = rp_id
               &&
                 match allow with
                 | Some ids -> List.mem p.credential_id ids
                 | None -> true
             then
               Some
                 (`Assoc
                    [
                      ( "domain",
                        `String
                          (Domain_name.to_string domain.Tsync_domain.Domain.name)
                      );
                      ("id", `String id);
                      ("credentialId", `String (b64 p.credential_id));
                      ("userName", `String p.user_name);
                      ("userDisplayName", `String p.user_display_name);
                      ("login", `String (title p.login));
                    ])
             else None)
           (passkeys ok)) );
  ]

let passkey_assert ~domain ~engine ~lazy_tree t args =
  let rp_id = check_rp args in
  let client_data_hash = client_data_hash args in
  let user_verified = user_verified ~domain ~engine ~lazy_tree t args in
  let ctx = context ~pull:(pull_of args) ~domain ~engine ~lazy_tree t in
  match find ctx (required args "id") with
    | Passkey p when p.rp_id = rp_id ->
        let authenticator_data =
          Webauthn.authenticator_data ~rp_id { user_verified } ()
        in
        [
          ("credentialId", `String (b64 p.credential_id));
          ("authenticatorData", `String (b64 authenticator_data));
          ( "signature",
            `String
              (b64
                 (Webauthn.sign ~private_key:p.private_key ~authenticator_data
                    ~client_data_hash)) );
          ("userHandle", `String (b64 p.user_handle));
        ]
    | _ -> Fail.invalid "the record is no passkey of %s" rp_id

(* §8: a login for the site that asks, never another site's. *)
let fill ~domain ~engine ~lazy_tree t args =
  let ctx = context ~pull:(pull_of args) ~domain ~engine ~lazy_tree t in
  let site = required args "site" and id = required args "id" in
  match find ctx id with
    | Login l
      when List.exists (fun s -> Passwords.matches ~site:s ~origin:site) l.urls
      ->
        [("username", `String l.username); ("password", `String l.password)]
        @ List.filter
            (fun (k, _) -> k = "code" || k = "secondsLeft")
            (code ~pull:(pull_of args) ~domain ~engine ~lazy_tree t l.totp)
    | _ -> Fail.invalid "the login does not match %s" site

(* §8 save: an equal login adds nothing; one login of the site and username
   with another password is updated only on [update] naming it; anything else
   is added. *)
let save ~domain ~engine ~lazy_tree t args =
  let site =
    match Passwords.site_of_string (required args "site") with
      | Ok site -> site
      | Error reason -> Fail.invalid "%s" reason
  in
  let username = required args "username"
  and password = required args "password" in
  let ctx = context ~writing:true ~domain ~engine ~lazy_tree t in
  let ok, _ = records ctx in
  let same =
    List.filter
      (fun (_, (l : Passwords.login)) ->
        l.username = username
        && List.exists (fun s -> Passwords.matches ~site:s ~origin:site) l.urls)
      (logins ok)
  in
  if List.exists (fun (_, (l : Passwords.login)) -> l.password = password) same
  then [("saved", `Bool false)]
  else (
    match (same, str args "update") with
      | [(id, _)], Some update when update = id ->
          ignore
            (edit ~domain ~engine ~lazy_tree t
               [("id", `String id); ("password", `String password)]);
          [("saved", `Bool true); ("id", `String id)]
      | [(id, _)], _ -> [("saved", `Bool false); ("update", `String id)]
      | _ ->
          add ~domain ~engine ~lazy_tree t
            [
              ("title", `String site);
              ("urls", `List [`String site]);
              ("username", `String username);
              ("password", `String password);
            ]
          |> List.cons ("saved", `Bool true))

let remove_record ~domain ~engine ~lazy_tree t args =
  remove ~domain ~engine ~lazy_tree t (required args "id");
  []

(* §5: a password saved nowhere; it needs no K. *)
let generate_password ~domain:_ ~engine:_ ~lazy_tree:_ _ args =
  [
    ( "password",
      `String
        (generated (Option.value ~default:(`Assoc []) (arg args "generate"))) );
  ]

let act ~domain ~engine ~lazy_tree t ~action args =
  let verb =
    match action with
      | "passwords_add" -> add
      | "passwords_list" -> list
      | "passwords_get" -> get
      | "passwords_fill" -> fill
      | "passwords_save" -> save
      | "passwords_edit" -> edit
      | "passwords_remove" -> remove_record
      | "passwords_import" -> import
      | "passwords_export" -> export
      | "passwords_generate" -> generate_password
      | "passwords_passkey_create" -> passkey_create
      | "passwords_passkey_match" -> passkey_match
      | "passwords_passkey_assert" -> passkey_assert
      | a -> Fail.invalid "unknown action: %s" a
  in
  verb ~domain ~engine ~lazy_tree t args
