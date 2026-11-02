open Tsync_core
open Tsync_store
module P = Tsync_http_proxy.Store_server
module Server = Tsync_http.Server
module L = Tsync_setup_link.Setup_link

let p fmt = Printf.printf (fmt ^^ "\n")
let secret = String.make 40 's'
let other_secret = String.make 40 'o'

let contains s sub =
  let n = String.length sub in
  let rec go i =
    i + n <= String.length s && (String.sub s i n = sub || go (i + 1))
  in
  go 0

let result = function Ok _ -> "ok" | Error e -> e

let route ?(share = `Off) ~secret name store =
  {
    P.name;
    domain = Domain_name.v name;
    secret;
    read_only = false;
    domain_settings =
      {
        chunk = 4096;
        symlinks = `Skip;
        lease = 20.;
        quarantine = 200.;
        settle = 420.;
        entry_commands = 64;
        projector = None;
        extensions = [];
        vault_lock = Tsync_core.Vault_lock.none;
      };
    store;
    share;
    wake = ignore;
  }

let links () =
  p "== link parsing (§2)";
  let key = String.make 43 'A' and token = String.make 32 'a' in
  List.iter
    (fun (what, text) -> p "%-24s %s" what (result (L.link_of_string text)))
    [
      ("https", Printf.sprintf "https://h.example/join/%s#%s" token key);
      ( "under a base path",
        Printf.sprintf "https://h.example/t/join/%s#%s" token key );
      ( "http to loopback",
        Printf.sprintf "http://127.0.0.1:8/join/%s#%s" token key );
      ("http elsewhere", Printf.sprintf "http://h.example/join/%s#%s" token key);
      ("no fragment", Printf.sprintf "https://h.example/join/%s" token);
      ("short key", Printf.sprintf "https://h.example/join/%s#AAAA" token);
      ( "upper-case token",
        Printf.sprintf "https://h.example/join/%s#%s"
          (String.uppercase_ascii token)
          key );
      ("a share link", Printf.sprintf "https://h.example/s/%s#%s" token key);
    ]

let () =
  links ();
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-setup-link-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let local name = Local.create ~name (Filename.concat root name) in
      let cloud = local "cloud" in
      let photos = local "photos" in
      let proxy =
        P.create ~max_concurrent:4
          [
            route ~secret "photos" photos;
            route ~secret:other_secret "notes" (local "notes");
            route ~secret "m" (local "m")
              ~share:
                (`Member
                   { Composite.name = "cloud"; role = Replica; store = cloud });
          ]
      in
      let server =
        Server.serve
          [Unix.ADDR_INET (Unix.inet_addr_loopback, 0)]
          (P.handle proxy)
      in
      let url =
        match Server.addresses server with
          | [ADDR_INET (_, port)] -> Printf.sprintf "http://127.0.0.1:%d" port
          | _ -> assert false
      in
      let client ?(secret = secret) domain =
        (Option.get (Driver.find "http-proxy")).create ~admission:Uplink.none
          ~domain:(Domain_name.v domain) ~name:"server"
          [("url", Field_spec.S url); ("secret", Field_spec.S secret)]
      in
      let get path =
        let r =
          Tsync_http.Client.request
            (Tsync_http.Client.endpoint url)
            ~meth:"GET" path
        in
        (r.status, r.headers, Bigstring.to_string r.body)
      in
      let backend s : L.backend = { name = "server"; url; secret = s } in
      let about =
        [
          { L.name = Domain_name.v "photos"; extensions = []; vault = None };
          {
            L.name = Domain_name.v "notes";
            extensions = ["totp"; "passwords"];
            vault = Some { color = "#16a34a"; icon = None };
          };
        ]
      in
      let make ?(expires = 3600.) () =
        L.create ~base:url
          ~expires:(Unix.gettimeofday () +. expires)
          ~from:"laptop" ~about
          [
            { L.name = Domain_name.v "photos"; backends = [backend secret] };
            {
              L.name = Domain_name.v "notes";
              backends = [backend other_secret];
            };
          ]
      in
      let write ?(through = client "photos") (link : L.link) stored =
        through.put
          (Option.get (Key.share link.token))
          (Bigstring.of_string (L.stored_to_string stored))
      in
      p "\n== round trip (§3, §4, §6.1)";
      let link, stored = make () in
      write link stored;
      let text = L.link_to_string link in
      p "link parses back: %b" (L.link_of_string text = Ok link);
      (match Result.bind (L.fetch link) (L.open_ link) with
        | Ok payload ->
            p "from %s" payload.from;
            List.iter
              (function
                | L.Joinable d ->
                    p "joinable %s: %s"
                      (Domain_name.to_string d.name)
                      (String.concat ", "
                         (List.map
                            (fun (b : L.backend) ->
                              Printf.sprintf "%s url=%b secret=%b" b.name
                                (b.url = url)
                                (b.secret = secret || b.secret = other_secret))
                            d.backends))
                | L.Unusable { name; reason } -> p "unusable %s: %s" name reason)
              payload.entries
        | Error e -> p "round trip failed: %s" e);
      p "\n== the answer the Android app reads (§6.3)";
      (match
         Yojson.Safe.from_string (Tsync_android.Android_host.setup_link text)
       with
        | `Assoc l ->
            let names k =
              match List.assoc_opt k l with
                | Some (`List items) ->
                    List.map
                      (fun i ->
                        match i with
                          | `Assoc f -> (
                              match List.assoc_opt "name" f with
                                | Some (`String n) -> (
                                    n
                                    ^ (match List.assoc_opt "url" f with
                                      | Some (`String u) when u = url ->
                                          " (url)"
                                      | _ -> "")
                                    ^
                                      match List.assoc_opt "vault" f with
                                      | Some _ -> " (vault)"
                                      | None -> "")
                                | _ -> "?")
                          | _ -> "?")
                      items
                | _ -> []
            in
            p "keys %s" (String.concat ", " (List.map fst l));
            p "domains %s" (String.concat ", " (names "domains"));
            p "about %s" (String.concat ", " (names "about"))
        | _ -> p "not an object");
      p "refused: %s"
        (Tsync_android.Android_host.setup_link "https://h.example");
      p "\n== nothing in clear (§8)";
      let body =
        Bigstring.to_string
          (Option.get (photos.get_opt (Option.get (Key.share link.token))))
      in
      p "manifest holds a secret: %b, the url: %b, the key: %b"
        (contains body secret) (contains body url)
        (contains body
           ( L.link_to_string link |> fun s ->
             String.sub s (String.index s '#' + 1) 43 ));
      p "\n== integrity (§4)";
      let flipped =
        let s = Bytes.of_string stored.sealed in
        Bytes.set s 30 (Char.chr (Char.code (Bytes.get s 30) lxor 1));
        { stored with sealed = Bytes.to_string s }
      in
      p "one byte altered: %s" (result (L.open_ link flipped));
      let moved, _ = make () in
      p "under another token: %s"
        (result (L.open_ { moved with key = link.key } stored));
      p "\n== confinement (security §6.4)";
      let other, other_stored = make () in
      p "written with another domain's secret: %s"
        (match
           write
             ~through:(client ~secret:other_secret "notes")
             other other_stored
         with
          | () -> "stored"
          | exception Fail.E f -> Fail.kind_name f.kind);
      let status, _, _ = get ("/s/" ^ link.token) in
      p "/s/<token>: %d" status;
      let listed = (client "photos").list_prefix Key.shares in
      p "a share-space listing shows it: %b"
        (List.exists
           (fun (e : Store.entry) -> contains (Key.to_string e.key) link.token)
           listed);
      p "\n== on a member (§4 placement)";
      let mlink, mstored =
        L.create ~base:url
          ~expires:(Unix.gettimeofday () +. 3600.)
          ~from:"laptop" ~about:[]
          [{ L.name = Domain_name.v "m"; backends = [backend secret] }]
      in
      write ~through:(client "m") mlink mstored;
      p "landed on the member: %b"
        (cloud.head_opt (Option.get (Key.share mlink.token)) <> None);
      p "served: %s" (result (L.fetch mlink));
      p "\n== the page (§7)";
      let status, headers, html = get ("/join/" ^ link.token) in
      let header h =
        Option.value ~default:"-" (Tsync_http.Codec.header headers h)
      in
      p "status %d" status;
      List.iter
        (fun h -> p "%s: %s" h (header h))
        [
          "content-type";
          "content-security-policy";
          "cache-control";
          "referrer-policy";
          "x-content-type-options";
        ];
      p "names photos: %b, notes: %b, a secret: %b"
        (contains html "\"photos\"")
        (contains html "\"notes\"")
        (contains html secret);
      let status, _, _ = get ("/join/" ^ link.token ^ "?json=1") in
      p "json: %d" status;
      let status, _, _ = get ("/join/" ^ String.make 32 'f') in
      p "unknown token: %d" status;
      p "\n== lifetime (§4, §5.2)";
      let old, old_stored = make ~expires:(-60.) () in
      write old old_stored;
      let status, _, _ = get ("/join/" ^ old.token) in
      p "expired page: %d" status;
      p "expired fetch: %b"
        (match L.fetch old with
          | Error e -> String.starts_with ~prefix:"This setup link expired on" e
          | Ok _ -> false);
      ignore ((client "photos").delete (Option.get (Key.share link.token)));
      p "revoked fetch: %s" (result (L.fetch link));
      Server.close server);
  Fs.rm_rf root;
  p "\n== joined domains (§6.2)";
  Tsync_config.Frontend.register "presenter"
    {
      fields = [];
      wizard = Some { systems = [`Linux]; question = "present it"; asks = [] };
      presenting = Some `Per_domain;
      commands_only = None;
      pulled = None;
      group = None;
      commands = [];
    };
  Tsync_config.Frontend.register "bystander"
    {
      fields = [];
      wizard = Some { systems = [`Linux]; question = "also this"; asks = [] };
      presenting = None;
      commands_only = None;
      pulled = None;
      group = None;
      commands = [];
    };
  let config =
    match Tsync_config.Config_wizard.new_config () with
      | `Assoc l ->
          `Assoc
            (l
            @ [
                ( "domains",
                  `List
                    [
                      Tsync_config.Config_wizard.joined_domain ~system:`Linux
                        ~name:"photos"
                        [
                          `Assoc
                            [
                              ("type", `String "http-proxy");
                              ("name", `String "server");
                              ("role", `String "main");
                              ("url", `String "https://h.example");
                              ("secret", `String secret);
                            ];
                        ];
                    ] );
              ])
      | j -> j
  in
  match Tsync_config.Config_wizard.prepare config with
    | Error e -> p "a new config with it is refused: %s" e
    | Ok j ->
        let d =
          (Tsync_config.Config.of_string (Yojson.Safe.to_string j)).domains
          |> List.hd
        in
        p "accepted; %s: frontends %s, versioning %b, extensions %s"
          (Domain_name.to_string d.name)
          (String.concat ", "
             (List.map
                (fun (f : Tsync_config.Config.frontend) -> f.ftype)
                d.frontends))
          d.versioning
          (match d.extensions with
            | None -> "the main's"
            | Some l -> String.concat "," l)
