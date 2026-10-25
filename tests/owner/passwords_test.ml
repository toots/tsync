(* The passwords verbs (spec extensions/passwords §5–§7, §10, §11) through a
   serving owner: logins, their TOTP link, import and export, and passkeys,
   whose signatures are verified here with the public key the creation gave. *)

open Tsync_core
open Tsync_ipc
open Tsync_owner

let p fmt = Printf.printf (fmt ^^ "\n%!")

(* Short: on macOS the owner's socket lives under the home directory. *)
let root = Printf.sprintf "/tmp/tsync-pw-%d" (Unix.getpid ())

let () =
  Fs.rm_rf root;
  List.iter
    (fun d -> Fs.mkdir_p ~perm:0o700 (Filename.concat root d))
    ["home"; "data"; "cache"];
  Unix.putenv "HOME" (Filename.concat root "home");
  Unix.putenv "XDG_DATA_HOME" (Filename.concat root "data");
  Unix.putenv "XDG_CACHE_HOME" (Filename.concat root "cache")

(* Where the bridge looks for the domain's owner. *)
let socket = Tsync_config.Paths.owner_socket (Domain_name.v "pw")

let config_text =
  Printf.sprintf
    {|{"name":"test","domains":[
  {"name":"pw","symlinks":"keep","versioning":true,"extensions":["passwords","totp"],"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/store"}]},
  {"name":"plain","symlinks":"keep","versioning":true,"extensions":["passwords"],"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/plain"}]}]}|}
    root root

let config = Tsync_config.Config.of_string config_text
let () = Unix.putenv "TSYNC_CONFIG_JSON" config_text

let ask ?(domain = "pw") fields =
  Ipc.call socket (`Assoc (("domain", `String domain) :: fields))

let s v = `String v
let field = Ipc.field
let member j k = match j with `Assoc l -> List.assoc_opt k l | _ -> None

let answer label r =
  match field r "error" with
    | Some e -> p "%-40s %s: %s" label (Option.get (field r "code")) e
    | None -> p "%-40s ok" label

let ids = Hashtbl.create 8

let show_id id =
  match Hashtbl.find_opt ids id with
    | Some n -> n
    | None ->
        let n = Printf.sprintf "<id%d>" (Hashtbl.length ids + 1) in
        Hashtbl.replace ids id n;
        n

let id_of label r =
  match field r "id" with
    | Some id ->
        p "%-40s %s" label (show_id id);
        id
    | None ->
        answer label r;
        ""

let b64 = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
let unb64 v = Base64.decode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet v

let hex s =
  String.concat ""
    (List.map (Printf.sprintf "%02x")
       (List.map Char.code (List.of_seq (String.to_seq s))))

let listing label =
  match member (ask [("action", s "passwords_list")]) "records" with
    | Some (`List rows) ->
        p "%s" label;
        List.iter
          (fun row ->
            let f k = Option.value ~default:"" (field row k) in
            match f "kind" with
              | "login" ->
                  p "  login %s %S %S code=%s dangling=%s passkeys=%s"
                    (show_id (f "id"))
                    (f "title") (f "username")
                    (Yojson.Safe.to_string (Option.get (member row "code")))
                    (Yojson.Safe.to_string (Option.get (member row "dangling")))
                    (match member row "passkeys" with
                      | Some (`List l) -> string_of_int (List.length l)
                      | _ -> "?")
              | _ ->
                  p "  passkey %s %s %S"
                    (show_id (f "id"))
                    (f "rpId") (f "userName"))
          rows
    | _ -> p "%s: no records" label

let store_holds needle =
  let rec walk dir =
    Array.exists
      (fun n ->
        let path = Filename.concat dir n in
        if Sys.is_directory path then walk path
        else (
          let body = In_channel.with_open_bin path In_channel.input_all in
          Text.contains body needle))
      (Sys.readdir dir)
  in
  walk (Filename.concat root "store")

(* A DER ECDSA signature as the two 32-byte integers verify takes. *)
let rs_of_der der =
  let int_at i =
    let len = Char.code der.[i + 1] in
    let v = String.sub der (i + 2) len in
    let v =
      if String.length v > 32 then String.sub v (String.length v - 32) 32
      else String.make (32 - String.length v) '\000' ^ v
    in
    (v, i + 2 + len)
  in
  let r, next = int_at 2 in
  let s, _ = int_at next in
  (r, s)

let public_key spki =
  match X509.Public_key.decode_der spki with
    | Ok (`P256 key) -> key
    | _ -> failwith "not a P-256 key"

let verifies ~key ~authenticator_data ~client_data_hash signature =
  let digest =
    Digestif.SHA256.(
      to_raw_string (digest_string (authenticator_data ^ client_data_hash)))
  in
  Mirage_crypto_ec.P256.Dsa.verify ~key (rs_of_der signature) digest

(* §9.1: the bridge as a browser runs it, length-prefixed JSON both ways. *)
let bridge_session messages =
  let to_bridge_r, to_bridge_w = Unix.pipe ~cloexec:true ()
  and from_bridge_r, from_bridge_w = Unix.pipe ~cloexec:true () in
  let pid =
    Unix.create_process Sys.argv.(1)
      [|
        Sys.argv.(1); "passwords"; "browser-host"; "chrome-extension://test/";
      |]
      to_bridge_r from_bridge_w Unix.stderr
  in
  Unix.close to_bridge_r;
  Unix.close from_bridge_w;
  let oc = Unix.out_channel_of_descr to_bridge_w
  and ic = Unix.in_channel_of_descr from_bridge_r in
  let replies =
    List.map
      (fun json ->
        let body = Yojson.Safe.to_string json in
        let header = Bytes.create 4 in
        Bytes.set_int32_ne header 0 (Int32.of_int (String.length body));
        output_bytes oc header;
        output_string oc body;
        flush oc;
        let header = Bytes.create 4 in
        really_input ic header 0 4;
        Yojson.Safe.from_string
          (really_input_string ic (Int32.to_int (Bytes.get_int32_ne header 0))))
      messages
  in
  close_out oc;
  ignore (Unix.waitpid [] pid);
  close_in ic;
  replies

let rec wait_serving n =
  match Ipc.call socket (`Assoc [("action", `String "ping")]) with
    | _ -> ()
    | exception _ when n > 0 ->
        Rt.sleep 0.05;
        wait_serving (n - 1)

let passphrase = "correct horse battery staple"

let logins () =
  p "== logins";
  let gh =
    id_of "add"
      (ask
         [
           ("action", s "passwords_add");
           ("title", s "GitHub");
           ("urls", `List [s "https://github.com/login"]);
           ("username", s "me@example.com");
           ("password", s "hunter2 hunter2");
         ])
  in
  (* android §5.1: fill answers only the site the login matches. *)
  let filled site =
    let r =
      ask [("action", s "passwords_fill"); ("site", s site); ("id", s gh)]
    in
    match field r "password" with
      | Some pw ->
          p "%-40s %s, exact %s" ("fill for " ^ site)
            (if pw = "hunter2 hunter2" then "the password" else "another")
            (match member r "exact" with
              | Some (`Bool b) -> string_of_bool b
              | _ -> "?")
      | None -> answer ("fill for " ^ site) r
  in
  filled "https://github.com";
  filled "https://gist.github.com";
  filled "https://evil.example";
  let saved label fields =
    let r = ask (("action", s "passwords_save") :: fields) in
    match field r "error" with
      | Some _ -> answer label r
      | None ->
          p "%-40s saved %s%s" label
            (match member r "saved" with
              | Some (`Bool b) -> string_of_bool b
              | _ -> "?")
            (match field r "update" with
              | Some id -> ", update " ^ show_id id
              | None -> "")
  in
  let site = ("site", s "https://example.org/signin") in
  saved "save, new" [site; ("username", s "a"); ("password", s "one")];
  saved "save, the same" [site; ("username", s "a"); ("password", s "one")];
  saved "save, another password"
    [site; ("username", s "a"); ("password", s "two")];
  (match
     field
       (ask
          [
            ("action", s "passwords_save");
            site;
            ("username", s "a");
            ("password", s "two");
          ])
       "update"
   with
    | Some id ->
        saved "save, approving the update"
          [site; ("username", s "a"); ("password", s "two"); ("update", s id)];
        saved "save, then the same"
          [site; ("username", s "a"); ("password", s "two")]
    | None -> p "save: no update named");
  saved "save, a bad site"
    [("site", s "ftp://x"); ("username", s "a"); ("password", s "x")];
  let gen =
    id_of "add, generated"
      (ask
         [
           ("action", s "passwords_add");
           ("title", s "Bank");
           ("urls", `List [s "https://bank.example"]);
           ("generate", `Assoc [("length", `Int 32); ("symbols", `Bool false)]);
         ])
  in
  let linked =
    id_of "add, with otpauth"
      (ask
         [
           ("action", s "passwords_add");
           ("title", s "ACME");
           ("urls", `List [s "https://acme.example"]);
           ("password", s "acme pass");
           ("otpauth", s "otpauth://totp/ACME:me?secret=JBSWY3DPEHPK3PXP");
         ])
  in
  answer "add, both password and generate"
    (ask
       [
         ("action", s "passwords_add");
         ("title", s "X");
         ("password", s "x");
         ("generate", `Assoc []);
       ]);
  let codes () =
    match member (ask [("action", s "totp_list")]) "records" with
      | Some (`List l) -> List.length l
      | _ -> -1
  in
  let before = codes () in
  answer "add, otpauth and a bad site"
    (ask
       [
         ("action", s "passwords_add");
         ("title", s "X");
         ("urls", `List [s "ftp://x"]);
         ("password", s "x");
         ("otpauth", s "otpauth://totp/Orphan:me?secret=JBSWY3DPEHPK3PXP");
       ]);
  p "%-40s %b" "  it left no TOTP record" (codes () = before);
  answer "add, a bad site"
    (ask
       [
         ("action", s "passwords_add");
         ("title", s "X");
         ("urls", `List [s "ftp://x"]);
         ("password", s "x");
       ]);
  answer "add on a domain without totp, otpauth"
    (ask ~domain:"plain"
       [
         ("action", s "passwords_add");
         ("title", s "X");
         ("password", s "x");
         ("otpauth", s "otpauth://totp/X:me?secret=JBSWY3DPEHPK3PXP");
       ]);
  listing "list";
  let g = ask [("action", s "passwords_get"); ("id", s gen)] in
  p "%-40s %d characters" "get, the generated password"
    (String.length (Option.value ~default:"" (field g "password")));
  let l = ask [("action", s "passwords_get"); ("id", s linked)] in
  p "%-40s password %b, code of %d digits" "get, the linked login"
    (field l "password" = Some "acme pass")
    (String.length (Option.value ~default:"" (field l "code")));
  answer "edit the title"
    (ask
       [("action", s "passwords_edit"); ("id", s gh); ("title", s "GitHub.com")]);
  answer "remove the linked TOTP record"
    (ask [("action", s "totp_remove"); ("id", s (Option.get (field l "totp")))]);
  listing "list, a link now dangling";
  (* §5: words, characters, and what is refused; a password saved nowhere. *)
  let generate label g =
    let r = ask [("action", s "passwords_generate"); ("generate", `Assoc g)] in
    match field r "password" with
      | Some pw -> pw
      | None ->
          answer label r;
          ""
  in
  let words =
    String.split_on_char '-' (generate "generate, words" [("words", `Int 6)])
  in
  p "%-40s %d words of letters: %b" "generate, 6 words" (List.length words)
    (List.for_all
       (fun w ->
         w <> ""
         && String.for_all (function 'a' .. 'z' -> true | _ -> false) w)
       words);
  let chars =
    generate "generate, 8 characters"
      [("length", `Int 8); ("symbols", `Bool false)]
  in
  p "%-40s %d letters and digits: %b" "generate, 8 without symbols"
    (String.length chars)
    (String.for_all
       (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true | _ -> false)
       chars);
  ignore (generate "generate, 3 words" [("words", `Int 3)]);
  ignore
    (generate "generate, words and a length"
       [("words", `Int 6); ("length", `Int 20)]);
  let worded =
    ask
      [
        ("action", s "passwords_add");
        ("title", s "Words");
        ("generate", `Assoc [("words", `Int 5)]);
      ]
  in
  let worded_id = Option.value ~default:"" (field worded "id") in
  let w = ask [("action", s "passwords_get"); ("id", s worded_id)] in
  p "%-40s %d words" "add with 5 words, then get"
    (List.length
       (String.split_on_char '-'
          (Option.value ~default:"" (field w "password"))));
  ignore (ask [("action", s "passwords_remove"); ("id", s worded_id)]);
  (* §2.1, §2.2: a note, fields, and what is refused. *)
  let entry name value secret =
    `Assoc [("name", s name); ("value", s value); ("secret", `Bool secret)]
  in
  let note =
    ask
      [
        ("action", s "passwords_add");
        ("kind", s "note");
        ("title", s "Wi-Fi");
        ("notes", s "the guest network");
        ("fields", `List [entry "SSID" "home" false; entry "key" "s3cret" true]);
      ]
  in
  let note_id = Option.value ~default:"" (field note "id") in
  let got = ask [("action", s "passwords_get"); ("id", s note_id)] in
  p "%-40s kind %s, notes %b, fields %s" "a note, then get"
    (Option.value ~default:"?" (field got "kind"))
    (field got "notes" = Some "the guest network")
    (match member got "fields" with
      | Some (`List l) ->
          String.concat ","
            (List.map
               (fun j ->
                 Option.value ~default:"?" (field j "name")
                 ^
                   match member j "secret" with
                   | Some (`Bool true) -> "*"
                   | _ -> "")
               l)
      | _ -> "none");
  let rows k =
    match member (ask (("action", s "passwords_list") :: k)) "records" with
      | Some (`List l) -> l
      | _ -> []
  in
  let noted = List.filter (fun r -> field r "kind" = Some "note") (rows []) in
  p "%-40s %d, its title %s, a field shown %b" "list, the notes"
    (List.length noted)
    (match noted with
      | r :: _ -> Option.value ~default:"?" (field r "title")
      | [] -> "-")
    (List.exists (fun r -> member r "fields" <> None) noted);
  p "%-40s %b" "a site's listing offers no note"
    (List.for_all
       (fun r -> field r "kind" <> Some "note")
       (rows [("site", s "https://github.com")]));
  List.iter
    (fun (title, url) ->
      answer ("add, " ^ title)
        (ask
           [
             ("action", s "passwords_add");
             ("title", s title);
             ("urls", `List [s url]);
             ("password", s "x");
           ]))
    [
      ("A shop id", "https://id.shop.example");
      ("Z shop help", "https://help.shop.example");
    ];
  p "%-40s %s" "a sibling host's listing, its own first"
    (String.concat ", "
       (List.filter_map
          (fun r -> field r "title")
          (rows [("site", s "https://help.shop.example")])));
  answer "a note with a password"
    (ask
       [
         ("action", s "passwords_add");
         ("kind", s "note");
         ("title", s "X");
         ("password", s "x");
       ]);
  answer "a field with no name"
    (ask
       [
         ("action", s "passwords_add");
         ("kind", s "note");
         ("title", s "X");
         ("fields", `List [entry "" "v" false]);
       ]);
  answer "33 fields"
    (ask
       [
         ("action", s "passwords_add");
         ("kind", s "note");
         ("title", s "X");
         ( "fields",
           `List (List.init 33 (fun i -> entry (string_of_int i) "v" false)) );
       ]);
  answer "edit a note's fields"
    (ask
       [
         ("action", s "passwords_edit");
         ("id", s note_id);
         ("fields", `List [entry "PIN" "1234" true]);
       ]);
  let got = ask [("action", s "passwords_get"); ("id", s note_id)] in
  p "%-40s %d" "  its fields now"
    (match member got "fields" with Some (`List l) -> List.length l | _ -> -1);
  ignore (ask [("action", s "passwords_remove"); ("id", s note_id)]);
  let fielded =
    ask
      [
        ("action", s "passwords_add");
        ("title", s "Bank fields");
        ("password", s "bank pass");
        ("fields", `List [entry "account" "12-34" false]);
      ]
  in
  let fielded_id = Option.value ~default:"" (field fielded "id") in
  let got = ask [("action", s "passwords_get"); ("id", s fielded_id)] in
  p "%-40s %d" "a login's fields, through get"
    (match member got "fields" with Some (`List l) -> List.length l | _ -> -1);
  ignore (ask [("action", s "passwords_remove"); ("id", s fielded_id)]);
  (* §5.1: the pick saves the login, the submit sets its username. *)
  let count () =
    match member (ask [("action", s "passwords_list")]) "records" with
      | Some (`List l) -> List.length l
      | _ -> -1
  in
  let before = count () in
  let sg =
    ask
      [
        ("action", s "passwords_suggest");
        ("site", s "https://signup.example/register");
        ("username", s "");
      ]
  in
  let sg_id = Option.value ~default:"" (field sg "id") in
  let got = ask [("action", s "passwords_get"); ("id", s sg_id)] in
  p "%-40s saved at once %b, its password the one answered %b" "suggest"
    (count () = before + 1)
    (field got "password" = field sg "password" && field sg "password" <> None);
  answer "save, suggested, the username"
    (ask
       [
         ("action", s "passwords_save");
         ("site", s "https://signup.example");
         ("username", s "new@example.com");
         ("suggested", s sg_id);
       ]);
  let got = ask [("action", s "passwords_get"); ("id", s sg_id)] in
  p "%-40s username %s, still one login %b" "  after the submit"
    (Option.value ~default:"?" (field got "username"))
    (count () = before + 1);
  answer "save, suggested, another site"
    (ask
       [
         ("action", s "passwords_save");
         ("site", s "https://other.example");
         ("username", s "x");
         ("suggested", s sg_id);
       ]);
  ignore (ask [("action", s "passwords_remove"); ("id", s sg_id)]);
  (* §4.3: an app's verified website, from a stand-in for the statement fetch. *)
  Atomic.set Tsync_owner.Well_known.fetch (fun host path ->
      if host = "example.com" && path = "/.well-known/assetlinks.json" then
        Some
          {|[{"relation":["delegate_permission/common.get_login_creds"],
              "target":{"namespace":"android_app","package_name":"com.example.app",
                        "sha256_cert_fingerprints":["AB:CD:EF"]}}]|}
      else None);
  let web =
    ask
      [
        ("action", s "passwords_add");
        ("title", s "Example");
        ("urls", `List [s "https://example.com"; s "https://other.com"]);
        ("username", s "app user");
        ("password", s "app pass");
      ]
  in
  let web_id = Option.value ~default:"" (field web "id") in
  let for_app certs =
    match
      member
        (ask
           [
             ("action", s "passwords_list");
             ("site", s "android://com.example.app");
             ("certs", `List (List.map s certs));
           ])
        "records"
    with
      | Some (`List l) -> List.exists (fun r -> field r "id" = Some web_id) l
      | _ -> false
  in
  p "%-40s %b" "an app, the first request" (for_app ["abcdef"]);
  let rec until n =
    for_app ["abcdef"]
    || n > 0
       &&
       (Rt.sleep 0.1;
        until (n - 1))
  in
  p "%-40s %b" "  a later request" (until 50);
  let filled =
    ask
      [
        ("action", s "passwords_fill");
        ("site", s "android://com.example.app");
        ("id", s web_id);
        ("certs", `List [s "abcdef"]);
      ]
  in
  p "%-40s %b" "  fill, for the app" (field filled "password" = Some "app pass");
  Rt.sleep 0.3;
  p "%-40s %b" "another certificate, later"
    (for_app ["000000"]
    ||
    (Rt.sleep 0.3;
     for_app ["000000"]));
  answer "fill, another certificate"
    (ask
       [
         ("action", s "passwords_fill");
         ("site", s "android://com.example.app");
         ("id", s web_id);
         ("certs", `List [s "000000"]);
       ]);
  ignore (ask [("action", s "passwords_remove"); ("id", s web_id)]);
  Tsync_owner.Asset_links_cache.reset ();
  linked

let import_export () =
  p "== import and export";
  let csv =
    "name,url,username,password,notes,login_totp\n\
     Mail,https://mail.example,me,mail \
     pass,,otpauth://totp/Mail:me?secret=JBSWY3DPEHPK3PXP\n\
     Empty,https://empty.example,me,,,\n\
     Shop,https://shop.example,me,shop pass,a note,\n"
  in
  let r = ask [("action", s "passwords_import"); ("text", s csv)] in
  p "%-40s added %s, skipped %s, seeds %s added %s dropped" "import"
    (Yojson.Safe.to_string (Option.get (member r "added")))
    (Yojson.Safe.to_string (Option.get (member r "skipped")))
    (Yojson.Safe.to_string (Option.get (member r "seedsAdded")))
    (Yojson.Safe.to_string (Option.get (member r "seedsDropped")));
  answer "export, a wrong passphrase"
    (ask
       [
         ("action", s "passwords_export");
         ("passphrase", s "not the one, longer");
       ]);
  let e =
    ask [("action", s "passwords_export"); ("passphrase", s passphrase)]
  in
  let rows =
    List.filter (( <> ) "")
      (String.split_on_char '\n'
         (String.concat ""
            (String.split_on_char '\r'
               (Option.value ~default:"" (field e "csv")))))
  in
  p "%-40s %d lines, passkeys %s, the shop row there %b" "export"
    (List.length rows)
    (Yojson.Safe.to_string (Option.get (member e "passkeys")))
    (List.exists (fun row -> Text.contains row "shop pass") rows)

let passkeys () =
  p "== passkeys";
  let client_data_hash =
    Digestif.SHA256.(
      to_raw_string (digest_string "{\"type\":\"webauthn.get\"}"))
  in
  let create ?(origin = "https://login.example.com") ?(rp = "example.com")
      ?(user = "me@example.com") ?(algorithms = [-7]) ?(extra = []) () =
    ask
      ([
         ("action", s "passwords_passkey_create");
         ("origin", s origin);
         ("rpId", s rp);
         ("userHandle", s (b64 "user-1"));
         ("userName", s user);
         ("userDisplayName", s "Me");
         ("algorithms", `List (List.map (fun a -> `Int a) algorithms));
         ("clientDataHash", s (b64 client_data_hash));
       ]
      @ extra)
  in
  let made = create () in
  let id = id_of "create" made in
  let credential = Option.get (field made "credentialId") in
  let key = public_key (unb64 (Option.get (field made "publicKey"))) in
  let auth_data = unb64 (Option.get (field made "authenticatorData")) in
  p "%-40s flags %02x, counter %s, attestation starts %s"
    "  its authenticator data"
    (Char.code auth_data.[32])
    (hex (String.sub auth_data 33 4))
    (String.sub
       (hex (unb64 (Option.get (field made "attestationObject"))))
       0 34);
  answer "create, excluded"
    (create ~extra:[("exclude", `List [s credential])] ());
  answer "create, an unsupported algorithm" (create ~algorithms:[-257] ());
  answer "create, RP ID github.io from evil.github.io"
    (create ~origin:"https://evil.github.io" ~rp:"github.io" ());
  answer "create, over http" (create ~origin:"http://example.com" ());
  answer "create, another site's RP ID" (create ~rp:"other.com" ());
  answer "create, a wrong passphrase"
    (create ~extra:[("passphrase", s "not the one, longer")] ());
  let verified =
    create ~user:"second@example.com" ~extra:[("passphrase", s passphrase)] ()
  in
  p "%-40s flags %02x" "create, the passphrase"
    (Char.code (unb64 (Option.get (field verified "authenticatorData"))).[32]);
  let second = id_of "  its id" verified in
  let matched allow =
    match
      member
        (ask
           ([
              ("action", s "passwords_passkey_match");
              ("origin", s "https://example.com");
              ("rpId", s "example.com");
            ]
           @ allow))
        "passkeys"
    with
      | Some (`List l) -> List.length l
      | _ -> -1
  in
  p "%-40s %d" "match, no allow-list" (matched []);
  p "%-40s %d" "match, allowing one" (matched [("allow", `List [s credential])]);
  p "%-40s %d" "match, an empty allow-list" (matched [("allow", `List [])]);
  (* §5: a list's passkey row carries its public ids. *)
    (match member (ask [("action", s "passwords_list")]) "records" with
    | Some (`List rows) ->
        p "%-40s %b" "list, a passkey's credential id"
          (List.exists
             (fun row ->
               field row "credentialId" = Some credential
               && field row "userHandle" <> None)
             rows)
    | _ -> p "list: no records");
  let asserted =
    ask
      [
        ("action", s "passwords_passkey_assert");
        ("origin", s "https://example.com");
        ("rpId", s "example.com");
        ("domain", s "pw");
        ("id", s id);
        ("clientDataHash", s (b64 client_data_hash));
        ("verified", `Bool true);
      ]
  in
  let authenticator_data =
    unb64 (Option.get (field asserted "authenticatorData"))
  in
  let signature = unb64 (Option.get (field asserted "signature")) in
  p "%-40s flags %02x, verifies %b, user handle %b" "assert, verified"
    (Char.code authenticator_data.[32])
    (verifies ~key ~authenticator_data ~client_data_hash signature)
    (field asserted "userHandle" = Some (b64 "user-1"));
  p "%-40s %b" "  over other client data"
    (verifies ~key ~authenticator_data ~client_data_hash:(String.make 32 'x')
       signature);
  answer "assert, another RP ID"
    (ask
       [
         ("action", s "passwords_passkey_assert");
         ("origin", s "https://other.com");
         ("rpId", s "other.com");
         ("domain", s "pw");
         ("id", s id);
         ("clientDataHash", s (b64 client_data_hash));
       ]);
  let fetched = ref [] and document = ref None in
  Atomic.set Tsync_owner.Well_known.fetch (fun host path ->
      fetched := (host ^ path) :: !fetched;
      !document);
  let related origin =
    create ~origin ~rp:"accounts.meta.com" ~user:"related@meta.com" ()
  in
  answer "create, related origins unreachable"
    (related "https://www.facebook.com");
  document := Some {|{"origins": ["https://www.facebook.com"]}|};
  answer "create, a related origin" (related "https://www.facebook.com");
  answer "create, an origin not listed" (related "https://evil.example");
  answer "create, an RP ID that is a public suffix"
    (create ~origin:"https://www.facebook.com" ~rp:"co.uk" ());
  p "%-40s %s" "fetched" (String.concat ", " (List.rev !fetched));
  let got = ask [("action", s "passwords_get"); ("id", s second)] in
  p "%-40s kind %s, a private key in the reply %b" "get, a passkey"
    (Option.get (field got "kind"))
    (member got "privateKey" <> None
    || Text.contains (Yojson.Safe.to_string got) "privateKey");
  listing "list, with passkeys"

let () =
  Owner.stop_on_signals ();
  Rt.run_sync (fun () ->
      let owner =
        Rt.async (fun () ->
            Owner.run ~socket config config.Tsync_config.Config.domains)
      in
      wait_serving 100;
      answer "list before init" (ask [("action", s "passwords_list")]);
      answer "init"
        (ask [("action", s "vault_init"); ("passphrase", s passphrase)]);
      answer "init plain"
        (ask ~domain:"plain"
           [("action", s "vault_init"); ("passphrase", s passphrase)]);
      ignore (logins ());
      import_export ();
      passkeys ();
      p "== the bridge (§9)";
      let replies =
        bridge_session
          [
            `Assoc [("type", s "status")];
            `Assoc [("type", s "match"); ("origin", s "https://github.com")];
            `Assoc [("type", s "unlock"); ("passphrase", s passphrase)];
            `Assoc [("type", s "match"); ("origin", s "https://other.example")];
            `Assoc
              [
                ("type", s "passkey_match");
                ("origin", s "https://example.com");
                ("rpId", s "example.com");
              ];
            `Assoc
              [
                ("type", s "save");
                ("domain", s "pw");
                ("origin", s "https://new.example");
                ("username", s "me");
                ("password", s "new pass");
              ];
            `Assoc
              [
                ("type", s "save");
                ("domain", s "pw");
                ("origin", s "https://new.example");
                ("username", s "me");
                ("password", s "new pass");
              ];
            `Assoc
              [
                ("type", s "save");
                ("domain", s "pw");
                ("origin", s "https://new.example");
                ("username", s "me");
                ("password", s "newer pass");
              ];
            Yojson.Safe.from_string {|"not an object"|};
          ]
      in
      List.iter
        (fun r ->
          match field r "error" with
            | Some e -> p "  refused %s: %s" (Option.get (field r "code")) e
            | None ->
                p "  %s"
                  (String.concat " "
                     (List.filter_map
                        (fun (k, v) ->
                          if k = "ok" then None
                          else
                            Some
                              (k ^ "="
                              ^
                                match v with
                                | `List l -> string_of_int (List.length l)
                                | `String x when Hashtbl.mem ids x ->
                                    Hashtbl.find ids x
                                | `String x when String.length x = 32 ->
                                    "<new id>"
                                | v -> Yojson.Safe.to_string v))
                        (match r with `Assoc l -> l | _ -> []))))
        replies;
      let fill origin id =
        match
          bridge_session
            [
              `Assoc
                [
                  ("type", s "fill");
                  ("origin", s origin);
                  ("domain", s "pw");
                  ("id", s id);
                ];
            ]
        with
          | [r] -> (
              match field r "error" with
                | Some e -> p "  fill from %s: refused %s" origin e
                | None ->
                    p "  fill from %s: password %b" origin
                      (field r "password" = Some "hunter2 hunter2"))
          | _ -> p "  fill: no reply"
      in
      let gh =
        Hashtbl.fold
          (fun id label acc -> if label = "<id1>" then id else acc)
          ids ""
      in
      (match
         bridge_session
           [
             `Assoc
               [
                 ("type", s "passkey_match");
                 ("origin", s "https://example.com");
                 ("rpId", s "example.com");
               ];
           ]
       with
        | [r] -> (
            match member r "passkeys" with
              | Some (`List (first :: _)) -> (
                  let id = Option.get (field first "id") in
                  match
                    bridge_session
                      [
                        `Assoc
                          [
                            ("type", s "passkey_assert");
                            ("domain", s "pw");
                            ("origin", s "https://example.com");
                            ("rpId", s "example.com");
                            ("id", s id);
                            ("clientDataHash", s (b64 (String.make 32 'c')));
                            ("verified", `Bool true);
                          ];
                      ]
                  with
                    | [a] ->
                        p
                          "  a browser's verified without the passphrase: \
                           flags %02x"
                          (Char.code
                             (unb64 (Option.get (field a "authenticatorData"))).[
                             32])
                    | _ -> p "  assert: no reply")
              | _ -> p "  no passkey to assert")
        | _ -> p "  passkey_match: no reply");
      fill "https://github.com" gh;
      fill "https://evil.example" gh;
      p "== the store";
      List.iter
        (fun needle -> p "%-40s %b" ("holds " ^ needle) (store_holds needle))
        ["hunter2"; "github.com"; "me@example.com"; "example.com"; "shop pass"];
      answer "lock" (ask [("action", s "vault_lock")]);
      answer "list, locked" (ask [("action", s "passwords_list")]);
      ignore (ask [("action", s "stop")]);
      p "owner exit status %d" (Rt.Promise.await owner));
  Fs.rm_rf root
