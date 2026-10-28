(* The passwords records, sites, generation and CSV (spec extensions/passwords
   §2, §4, §5, §7.1, §10, §11). *)

open Tsync_vault

let p fmt = Printf.printf fmt

let sites () =
  p "== §4.1 sites\n";
  List.iter
    (fun s ->
      match Passwords.site_of_string s with
        | Ok site -> p "%-45s -> %s\n" s site
        | Error e -> p "%-45s refused: %s\n" s e)
    [
      "https://example.com";
      "https://example.com/login?next=/#top";
      "HTTPS://Login.Example.COM/";
      "https://example.com:443";
      "http://example.com:80/x";
      "https://example.com:8443/";
      "http://example.com:443";
      "https://user:pass@example.com/";
      "  https://example.com  ";
      "https://bücher.example";
      "https://BÜCHER.example/path";
      "https://münchen.de";
      "https://例え.テスト";
      "https://xn--bcher-kva.example";
      "https://[::1]:8080/";
      "https://router";
      "android://com.example.app";
      "android://AbCd_ef==@com.example.app/";
      "ftp://example.com";
      "example.com";
      "https://";
      "https://exa mple.com";
      "https://example..com";
      "https://example.com:0";
      "https://example.com:65536";
      "https://example.com:http";
      "https://ex%41mple.com";
      "android://1com.example";
      "android://com..example";
    ]

let matching () =
  p "\n== §4.2 matching\n";
  List.iter
    (fun (site, origin) ->
      p "%-27s %-30s %b\n" site origin (Passwords.matches ~site ~origin))
    [
      ("https://example.com", "https://example.com");
      ("https://example.com", "https://login.example.com");
      ("https://example.com", "https://a.b.example.com");
      ("https://example.com", "http://example.com");
      ("https://example.com", "https://badexample.com");
      ("https://example.com", "https://example.com:8443");
      ("https://example.com", "https://example.com:443");
      ("https://example.com", "https://EXAMPLE.com");
      ("https://login.example.com", "https://example.com");
      ("https://example.com:8443", "https://example.com:8443");
      ("http://example.com", "http://example.com");
      ("http://example.com", "https://example.com");
      ("http://example.com:443", "https://example.com");
      ("https://router", "https://router");
      ("https://router", "https://x.router");
      ("https://router", "http://router");
      ("https://co.uk", "https://bank.co.uk");
      ("https://idmsa.apple.com", "https://iforgot.apple.com");
      ("https://alice.github.io", "https://bob.github.io");
      ("https://github.io", "https://alice.github.io");
      ("https://alice.s3.amazonaws.com", "https://bob.s3.amazonaws.com");
      ("https://a.amazonaws.com", "https://b.amazonaws.com");
      ("https://bank.co.uk", "https://login.bank.co.uk");
      ("https://10.0.0.1", "https://192.168.0.1");
      ("https://10.0.0.1", "https://10.0.0.1");
      ("android://com.example.app", "android://com.example.app");
      ("android://com.example.app", "android://com.example.app2");
      ("android://com.example.app", "https://com.example.app");
      ("https://example.com", "android://com.example");
    ]

let in_alphabet ~symbols s =
  String.for_all
    (function
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' -> true
      | c -> symbols && String.contains "!#%+-.=?@_~" c)
    s

let generation () =
  p "\n== §5 generation\n";
  List.iter
    (fun (length, symbols) ->
      match Passwords.generate ~length ~symbols with
        | Ok s ->
            p "length %3d symbols %-5b -> %d characters, in the alphabet %b\n"
              length symbols (String.length s) (in_alphabet ~symbols s)
        | Error e -> p "length %3d symbols %-5b refused: %s\n" length symbols e)
    [(8, false); (20, true); (128, true); (7, false); (129, true)];
  (* Over many draws every alphabet symbol shows and none other does. *)
  let seen = Hashtbl.create 80 in
  for _ = 1 to 200 do
    match Passwords.generate ~length:128 ~symbols:true with
      | Ok s -> String.iter (fun c -> Hashtbl.replace seen c ()) s
      | Error _ -> assert false
  done;
  p "distinct characters over 200 draws: %d\n" (Hashtbl.length seen)

let id = String.make 32 'a'

let login : Passwords.login =
  {
    title = "GitHub";
    urls = ["https://github.com"; "android://com.github.android"];
    username = "me@example.com";
    password = "correct horse battery staple";
    notes = "line one\nline \"two\", with a comma";
    totp = id;
    fields = [];
    modified = 1760500000;
    unknown = [("future", `List [`Int 1; `String "x"])];
  }

let passkey : Passwords.passkey =
  {
    rp_id = "github.com";
    credential_id = String.init 32 (fun i -> Char.chr i);
    user_handle = "\x00\xffuser";
    user_name = "me@example.com";
    user_display_name = "Me";
    algorithm = -7;
    private_key = String.init 32 (fun i -> Char.chr (255 - i));
    login = id;
    created = 1760400000;
    modified = 1760500000;
    unknown = [("future", `Bool true)];
  }

let round_trips () =
  p "\n== §2, §7.1 round trips\n";
  List.iter
    (fun (name, r) ->
      let s = Passwords.to_string r in
      p "%s: %d bytes, multiple of 256 %b, round trip %b\n  %s\n" name
        (String.length s)
        (String.length s mod 256 = 0)
        (Passwords.of_string s = Ok r)
        (String.trim s))
    [
      ("login", Passwords.Login login);
      ( "login with a field",
        Passwords.Login
          {
            login with
            fields =
              [
                {
                  name = "PIN";
                  value = "1234";
                  secret = true;
                  unknown = [("future", `Int 2)];
                };
              ];
          } );
      ("passkey", Passwords.Passkey passkey);
    ];
  let bare =
    Passwords.Login { login with notes = String.make 300 'n'; unknown = [] }
  in
  p "a login over 256 bytes pads to %d\n"
    (String.length (Passwords.to_string bare));
  p "key fields differ by kind %b; a title change keeps them %b\n"
    (Passwords.key_fields (Login login)
    <> Passwords.key_fields (Passkey passkey))
    (Passwords.key_fields (Login login)
    = Passwords.key_fields (Login { login with title = "Other" }));
  p "modified %d %d\n"
    (Passwords.modified (Login login))
    (Passwords.modified (Passkey { passkey with modified = 7 }))

(* Every CORRUPT reason, and none names the secret it was given. *)
let corrupt () =
  p "\n== §2, §7.1 CORRUPT\n";
  let secrets =
    [
      login.password;
      Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
        passkey.private_key;
    ]
  in
  let leaks = ref 0 in
  let edit r f =
    match Yojson.Safe.from_string (Passwords.to_string r) with
      | `Assoc l -> Yojson.Safe.to_string (`Assoc (f l))
      | _ -> assert false
  in
  let set k v l = (k, v) :: List.remove_assoc k l in
  let without k l = List.remove_assoc k l in
  let lg f = edit (Login login) f and pk f = edit (Passkey passkey) f in
  List.iter
    (fun (name, s) ->
      match Passwords.of_string s with
        | Ok _ -> p "%-32s accepted\n" name
        | Error e ->
            if List.exists (fun x -> Tsync_core.Text.contains e x) secrets then
              incr leaks;
            p "%-32s %s\n" name e)
    [
      ("not JSON", "{\"password\":\"correct horse battery staple\"");
      ("not UTF-8", "{\"kind\":\"login\",\"title\":\"\xff\"}");
      ("array", "[]");
      ("no kind", lg (without "kind"));
      ("kind other", lg (set "kind" (`String "card")));
      ("no password", lg (without "password"));
      ("password an int", lg (set "password" (`Int 3)));
      ("empty password", lg (set "password" (`String "")));
      ( "password 1025 bytes",
        lg (set "password" (`String (String.make 1025 'x'))) );
      ( "password 1024 bytes",
        lg (set "password" (`String (String.make 1024 'x'))) );
      ("empty title", lg (set "title" (`String "")));
      ("title 257 bytes", lg (set "title" (`String (String.make 257 't'))));
      ("urls not strings", lg (set "urls" (`List [`Int 1])));
      ( "33 urls",
        lg
          (set "urls" (`List (List.init 33 (fun _ -> `String "https://a.com"))))
      );
      ("url with a path", lg (set "urls" (`List [`String "https://a.com/x"])));
      ("url upper case", lg (set "urls" (`List [`String "https://A.com"])));
      ("notes over 64 KiB", lg (set "notes" (`String (String.make 65537 'n'))));
      ("totp not an id", lg (set "totp" (`String "ABC")));
      ("no modified", lg (without "modified"));
      ("modified a float", lg (set "modified" (`Float 1.5)));
      ("rpId upper case", pk (set "rpId" (`String "GitHub.com")));
      ("rpId with port", pk (set "rpId" (`String "github.com:443")));
      ("rpId IDN", pk (set "rpId" (`String "bücher.example")));
      ("rpId A-label", pk (set "rpId" (`String "xn--bcher-kva.example")));
      ( "credentialId 31 bytes",
        pk (set "credentialId" (`String (String.make 42 'A'))) );
      ( "credentialId padded",
        pk (set "credentialId" (`String (String.make 43 'A' ^ "="))) );
      ( "credentialId std base64",
        pk (set "credentialId" (`String (String.make 42 'A' ^ "+"))) );
      ("userHandle empty", pk (set "userHandle" (`String "")));
      ( "userHandle 65 bytes",
        pk
          (set "userHandle"
             (`String
                (Base64.encode_string ~pad:false
                   ~alphabet:Base64.uri_safe_alphabet (String.make 65 'u')))) );
      ("userName 257 bytes", pk (set "userName" (`String (String.make 257 'u'))));
      ("algorithm -8", pk (set "algorithm" (`Int (-8))));
      ( "privateKey 33 bytes",
        pk
          (set "privateKey"
             (`String
                (Base64.encode_string ~pad:false
                   ~alphabet:Base64.uri_safe_alphabet (String.make 33 'k')))) );
      ("login not an id", pk (set "login" (`String "x")));
      ("no created", pk (without "created"));
      ("padded with spaces", Passwords.to_string (Login login));
    ];
  p "reasons naming a secret: %d\n" !leaks

let show_rows = function
  | Error e -> p "refused: %s\n" e
  | Ok ((rows : Passwords.row list), skipped) ->
      List.iter
        (fun (r : Passwords.row) ->
          p
            "line %d: title %S urls [%s] username %S password %S notes %S \
             otpauth %S\n"
            r.line r.title
            (String.concat "; " r.urls)
            r.username r.password r.notes r.otpauth)
        rows;
      List.iter (fun (line, why) -> p "line %d skipped: %s\n" line why) skipped

let csv () =
  p "\n== §10 export\n";
  let plain : Passwords.login =
    {
      login with
      title = "Bank, \"main\"";
      urls = [];
      totp = "";
      fields = [];
      notes = "";
      unknown = [];
    }
  in
  let otpauth (l : Passwords.login) =
    if l.totp = "" then ""
    else "otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP"
  in
  let exported = Passwords.export_csv ~otpauth [login; plain] in
  print_string exported;
  p "\n== §10.1 import of the export\n";
  let imported = Passwords.import_csv exported in
  show_rows imported;
  (match imported with
    | Ok ([a; b], []) ->
        let same (l : Passwords.login) (r : Passwords.row) =
          l.title = r.title
          && (match l.urls with [] -> r.urls = [] | u :: _ -> r.urls = [u])
          && l.username = r.username && l.password = r.password
          && l.notes = r.notes
          && otpauth l = r.otpauth
        in
        p "reproduces every field %b\n" (same login a && same plain b)
    | _ -> p "reproduces every field false\n");
  p "\n== §10.1 Bitwarden CSV\n";
  show_rows
    (Passwords.import_csv
       "\xef\xbb\xbffolder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n\
        ,,login,GitHub,,,0,https://github.com/login,me@example.com,hunter2hunter2,otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP\n\
        ,,login,Empty,,,0,https://empty.example,me,,\n\
        ,,note,\"Multi\n\
        line\",\"a, b\",,0,,,,\n\
        ,,login,,,,0,https://Example.ORG:443/x,u,p@ss,\n\
        ,,login,Bad,,,0,ftp://example.com,u,pw,\n\n\
        ,,login,NoSite,,,0,,u,\"quo\"\"ted\",\n");
  p "\n== §10.1 refused files\n";
  show_rows (Passwords.import_csv "name,url,username\nA,https://a.com,u\n");
  show_rows (Passwords.import_csv "");
  show_rows
    (Passwords.import_csv
       "Name,URL,Password\r\nA,https://a.com,\"unterminated\r\n");
  show_rows
    (Passwords.import_csv "Name,URL,Password\r\nA,https://a.com,pw\r\nB,,pw2")

(* §4.3: the candidate rule and what a statement grants. *)
let asset_links () =
  p "\n== an app's websites (Digital Asset Links)\n";
  let module A = Tsync_vault.Asset_links in
  List.iter
    (fun (package, host) ->
      p "%-44s %b\n" (package ^ " / " ^ host) (A.candidate ~package host))
    [
      ("com.github.android", "github.com");
      ("com.amazon.mShop.android.shopping", "amazon.com");
      ("com.github.android", "gitlab.com");
      ("com.example", "example");
      ("org.example.app", "com.example.org");
    ];
  let statement ?(relation = "delegate_permission/common.get_login_creds")
      ?(namespace = "android_app") ?(package = "com.example.app")
      ?(cert = "AB:CD:EF") () =
    Printf.sprintf
      {|[{"relation":["delegate_permission/common.handle_all_urls","%s"],
          "target":{"namespace":"%s","package_name":"%s","sha256_cert_fingerprints":["%s"]}}]|}
      relation namespace package cert
  in
  let grants label body =
    p "%-44s %b\n" label
      (A.grants ~package:"com.example.app" ~certs:["abcdef"] body)
  in
  grants "a matching statement" (statement ());
  grants "its fingerprint in lower case, no colons"
    (statement ~cert:"abcdef" ());
  grants "another certificate" (statement ~cert:"AB:CD:00" ());
  grants "another package" (statement ~package:"com.example.other" ());
  grants "handle_all_urls alone"
    (statement ~relation:"delegate_permission/common.handle_all_urls" ());
  grants "a web target" (statement ~namespace:"web" ());
  grants "not JSON" "<html>"

let () =
  (* The CSV holds CRLF, which Windows' text mode would write as CR CR LF. *)
  set_binary_mode_out stdout true;
  asset_links ();
  sites ();
  matching ();
  generation ();
  round_trips ();
  corrupt ();
  csv ()
