open Tsync_config

let p fmt = Printf.printf fmt
let secret = String.make 40 'x'

let domain ?(extra = "") ?(extensions = Some "[]")
    ?(backends =
      {|[{"type":"local","name":"disk","role":"main","path":"/srv/d"}]|})
    ?(frontends = {|["fuse"]|}) name =
  Printf.sprintf
    {|{"name":%S,"symlinks":"keep","versioning":true,"backends":%s%s,"frontends":%s%s}|}
    name backends
    (match extensions with
      | Some e -> Printf.sprintf {|,"extensions":%s|} e
      | None -> "")
    frontends extra

let config ?(top = "") domains =
  Printf.sprintf {|{"name":"laptop"%s,"domains":[%s]}|} top
    (String.concat "," domains)

let try_ what s =
  match Config.of_string s with
    | c ->
        p "%-40s ok: %s\n" what
          (String.concat "; "
             (List.map
                (fun (d : Config.domain) ->
                  Printf.sprintf "%s ro=%b backends=%s%s"
                    (Tsync_core.Domain_name.to_string d.name)
                    d.read_only
                    (String.concat ","
                       (List.map
                          (fun (b : Config.backend) ->
                            b.bname ^ ":"
                            ^ Tsync_store.Composite.role_to_string b.role)
                          d.backends))
                    (match d.extensions with
                      | None -> " extensions follow the main"
                      | Some [] -> ""
                      | Some l -> " extensions=" ^ String.concat "," l))
                c.domains))
    | exception Config.Invalid e -> p "%-40s refused: %s\n" what e

let () =
  p "== accepted\n";
  try_ "minimal" (config [domain "Files"]);
  try_ "read order main < replica < archive < backfill"
    (config
       [
         domain
           ~backends:
             {|[{"type":"local","name":"b","role":"backfill","path":"/b"},{"type":"local","name":"a","role":"readOnly","path":"/a"},{"type":"local","name":"r","role":"replica","path":"/r"},{"type":"local","name":"m","role":"main","path":"/m"}]|}
           "Files";
       ]);
  try_ "a lone readOnly store forces read-only"
    (config
       [
         domain
           ~backends:
             {|[{"type":"local","name":"a","role":"readOnly","path":"/a"}]|}
           "Archive";
       ]);
  try_ "sizes and string booleans"
    (config
       [
         domain
           ~extra:{|,"chunkSize":"8M","maxCache":"1.5 GiB","readOnly":"no"|}
           "Files";
       ]);
  try_ "fuse ownership and modes for a group"
    (config
       [
         domain
           ~frontends:
             {|[{"type":"fuse","allowOther":true,"uid":"1000","gid":"root","fileMode":"0664","dirMode":"775"}]|}
           "Media";
       ]);
  p "\n== advanced keys: what is in force\n";
  let in_force what extra =
    let bare =
      Printf.sprintf
        {|{"domains":[{"name":"F","versioning":true,"backends":[{"type":"local","name":"d","role":"main","path":"/srv/d"}],"extensions":[],"frontends":["android"]%s}]}|}
        extra
    in
    match Config.of_string bare with
      | { domains = [d]; _ } ->
          let t = Config.tuning d in
          p
            "%-22s symlinks %s, batch %g s, width %d, entry %d, lease %g, \
             quarantine %g, settle %g\n"
            what
            (match d.symlinks with
              | None -> "unset"
              | Some `Keep -> "keep"
              | Some `Follow -> "follow"
              | Some `Skip -> "skip")
            t.batch_delay t.project_width t.max_entry_commands t.project_lease
            t.project_quarantine t.project_settle
      | _ -> p "%-22s not one domain\n" what
      | exception Config.Invalid e -> p "%-22s refused: %s\n" what e
  in
  in_force "none set" "";
  in_force "all set"
    {|,"symlinks":"skip","batchDelay":0,"projectWidth":4,"maxEntryCommands":1024,"projectLease":20,"projectQuarantine":200,"projectSettle":420|};
  in_force "settle under quarantine" {|,"projectSettle":120|};
  in_force "lease over quarantine" {|,"projectLease":400|};
  in_force "a width of 0" {|,"projectWidth":0|};
  in_force "an entry of 0" {|,"maxEntryCommands":0|};
  in_force "a negative delay" {|,"batchDelay":-1|};
  in_force "a lease of 0" {|,"projectLease":0|};
  in_force "a bad policy" {|,"symlinks":"sometimes"|};
  in_force "a delay that is no number" {|,"batchDelay":"nan"|};
  in_force "a settle without end" {|,"projectSettle":"inf"|};
  p "\n== domain-wide settings against what the main states\n";
  let against what extra =
    let bare =
      Printf.sprintf
        {|{"domains":[{"name":"F","versioning":true,"backends":[{"type":"local","name":"d","role":"main","path":"/srv/d"}],"frontends":["android"]%s}]}|}
        extra
    in
    let main : Tsync_store.Store.domain_settings =
      {
        chunk = 8 lsl 20;
        symlinks = `Follow;
        lease = 20.;
        quarantine = 200.;
        settle = 420.;
        entry_commands = 1024;
        projector = None;
        extensions = ["totp"];
        vault_lock = Tsync_core.Vault_lock.none;
      }
    in
    let wire =
      Tsync_store.Store.(domain_settings_of_json (domain_settings_to_json main))
    in
    match Config.of_string bare with
      | { domains = [d]; _ } -> (
          match Config.in_force d wire with
            | t, symlinks ->
                p
                  "%-26s symlinks %s, entry %d, lease %g, quarantine %g, \
                   settle %g, batch %g s\n"
                  what
                  (match symlinks with
                    | `Keep -> "keep"
                    | `Follow -> "follow"
                    | `Skip -> "skip")
                  t.max_entry_commands t.project_lease t.project_quarantine
                  t.project_settle t.batch_delay
            | exception Tsync_core.Fail.E f ->
                p "%-26s refused: %s\n" what f.reason)
      | _ -> p "%-26s not one domain\n" what
  in
  against "nothing configured" "";
  against "the main's extensions" {|,"extensions":["totp"]|};
  against "no extension" {|,"extensions":[]|};
  against "one the main lacks" {|,"extensions":["totp","passwords"]|};
  against "the same as the main" {|,"symlinks":"follow","projectSettle":420|};
  against "a smaller entry" {|,"maxEntryCommands":64,"batchDelay":1|};
  against "a larger entry" {|,"maxEntryCommands":4096|};
  against "another policy" {|,"symlinks":"keep"|};
  against "another settle" {|,"projectSettle":500|};
  p "\n== the vault's auto-lock against what the main states (05 rule 7)\n";
  let auto what ~main extra =
    let stated : Tsync_store.Store.domain_settings option =
      Option.map
        (fun j : Tsync_store.Store.domain_settings ->
          {
            chunk = 8 lsl 20;
            symlinks = `Keep;
            lease = 30.;
            quarantine = 300.;
            settle = 600.;
            entry_commands = 256;
            projector = None;
            extensions = ["totp"];
            vault_lock =
              Result.get_ok
                (Tsync_core.Vault_lock.of_json (Yojson.Safe.from_string j));
          })
        main
    in
    let wire =
      Option.bind stated (fun m ->
          Tsync_store.Store.(
            domain_settings_of_json (domain_settings_to_json m)))
    in
    match
      Config.of_string
        (Printf.sprintf
           {|{"domains":[{"name":"F","versioning":true,"backends":[{"type":"local","name":"d","role":"main","path":"/srv/d"}],"frontends":["android"]%s}]}|}
           extra)
    with
      | { domains = [d]; _ } ->
          p "%-30s %s from %s\n" what
            (Yojson.Safe.to_string
               (Tsync_core.Vault_lock.to_json
                  (Config.vault_lock_in_force d wire)))
            (String.concat ","
               (List.map
                  (fun (k, v) -> k ^ "=" ^ v)
                  (Config.vault_lock_sources d wire)))
      | _ -> p "%-30s not one domain\n" what
      | exception Config.Invalid e -> p "%-30s refused: %s\n" what e
  in
  auto "none" ~main:None "";
  auto "the domain's own" ~main:None
    {|,"vaultLock":{"idleMinutes":30,"onScreenLock":true}|};
  auto "the main's" ~main:(Some {|{"idleMinutes":10,"maxHours":12}|}) "";
  auto "stricter than the main" ~main:(Some {|{"idleMinutes":10}|})
    {|,"vaultLock":{"idleMinutes":5}|};
  auto "looser than the main" ~main:(Some {|{"idleMinutes":10,"maxHours":12}|})
    {|,"vaultLock":{"idleMinutes":30,"onScreenLock":true}|};
  auto "an empty policy" ~main:None {|,"vaultLock":{}|};
  auto "idle of 0" ~main:None {|,"vaultLock":{"idleMinutes":0}|};
  auto "idle over a day" ~main:None {|,"vaultLock":{"idleMinutes":1441}|};
  auto "hours as text" ~main:None {|,"vaultLock":{"maxHours":"12"}|};
  auto "screen as 1" ~main:None {|,"vaultLock":{"onScreenLock":1}|};
  auto "not an object" ~main:None {|,"vaultLock":true|};
  p "%-30s %b\n" "an ill-formed stated policy"
    (Tsync_store.Store.domain_settings_of_json
       (Yojson.Safe.from_string
          {|{"chunkSize":8388608,"symlinks":"keep","projectLease":30,"projectQuarantine":300,"projectSettle":600,"maxEntryCommands":256,"vaultLock":{"idleMinutes":0}}|})
    = None);
  p "\n== behind a server, a timing left out is the server's\n";
  let behind what extra =
    match
      Config.of_string
        (Printf.sprintf
           {|{"domains":[{"name":"F","versioning":true,"backends":[{"type":"http-proxy","name":"nas","role":"main","url":"https://nas.example:8443","secret":"0123456789abcdef0123456789abcdef"}],"extensions":[],"frontends":["android"]%s}]}|}
           extra)
    with
      | _ -> p "%-34s accepted\n" what
      | exception Config.Invalid e -> p "%-34s refused: %s\n" what e
  in
  behind "a lease above the default quarantine" {|,"projectLease":400|};
  behind "two of them out of order"
    {|,"projectLease":400,"projectQuarantine":300|};
  p "\n== a projector that is no client id\n";
  List.iter
    (fun (what, projector) ->
      p "%-22s %s\n" what
        (match
           Tsync_store.Store.domain_settings_of_json
             (`Assoc
                ([
                   ("chunkSize", `Int (8 lsl 20));
                   ("symlinks", `String "keep");
                   ("projectLease", `Int 30);
                   ("projectQuarantine", `Int 300);
                   ("projectSettle", `Int 600);
                   ("maxEntryCommands", `Int 256);
                 ]
                @ projector))
         with
          | Some { projector = Some p; _ } -> "stated, projector " ^ p
          | Some { projector = None; _ } -> "stated, no projector"
          | None -> "not stated"))
    [
      ("none", []);
      ("a client id", [("projector", `String (String.make 32 'a'))]);
      ("not a client id", [("projector", `String "the server")]);
      ("not a string", [("projector", `Int 7)]);
    ];
  p "\n== refused, each naming its path\n";
  try_ "unknown top-level key" (config ~top:{|,"maxUpload":4|} [domain "Files"]);
  try_ "unknown backend key"
    (config
       [
         domain
           ~backends:
             {|[{"type":"local","name":"d","role":"main","path":"/d","bukcet":"x"}]|}
           "Files";
       ]);
  try_ "missing versioning"
    {|{"domains":[{"name":"F","symlinks":"keep","backends":[{"type":"local","name":"d","role":"main","path":"/d"}],"extensions":[],"frontends":["fuse"]}]}|};
  try_ "reserved domain name" (config [domain "gc-jobs"]);
  try_ "SHARES beside a local store" (config [domain "SHARES"]);
  try_ "duplicate domain ignoring case"
    (config [domain "Files"; domain "files"]);
  try_ "replica without main"
    (config
       [
         domain
           ~backends:
             {|[{"type":"local","name":"r","role":"replica","path":"/r"}]|}
           "F";
       ]);
  try_ "link on a local store"
    (config
       [
         domain
           ~backends:
             {|[{"type":"local","name":"d","role":"main","path":"/d","link":"wan"}]|}
           "F";
       ]);
  try_ "relative local path"
    (config
       [
         domain
           ~backends:{|[{"type":"local","name":"d","role":"main","path":"d"}]|}
           "F";
       ]);
  try_ "member named .."
    (config
       [
         domain
           ~backends:
             {|[{"type":"local","name":"..","role":"main","path":"/d"}]|}
           "F";
       ]);
  try_ "short http-proxy secret"
    (config
       [domain ~frontends:{|[{"type":"http-proxy","secret":"short"}]|} "F"]);
  try_ "plain http to a remote host"
    (config
       [
         domain
           ~backends:
             (Printf.sprintf
                {|[{"type":"http-proxy","name":"nas","role":"main","url":"http://nas.lan:8080","secret":"%s"}]|}
                secret)
           "F";
       ]);
  try_ "plain http to loopback"
    (config
       [
         domain
           ~backends:
             (Printf.sprintf
                {|[{"type":"http-proxy","name":"nas","role":"main","url":"http://127.0.0.1:8080","secret":"%s"}]|}
                secret)
           "F";
       ]);
  try_ "two presenting frontends"
    (config [domain ~frontends:{|["fuse","android"]|} "F"]);
  try_ "backend type not built"
    (config
       [
         domain
           ~backends:{|[{"type":"ftp","name":"f","role":"main","link":"x"}]|}
           "F";
       ]);
  try_ "frontend type not built" (config [domain ~frontends:{|["webdav"]|} "F"]);
  try_ "fuse mode not octal"
    (config [domain ~frontends:{|[{"type":"fuse","fileMode":"0684"}]|} "F"]);
  try_ "fuse mode with special bits"
    (config [domain ~frontends:{|[{"type":"fuse","dirMode":"4755"}]|} "F"]);
  try_ "fuse unknown user"
    (config
       [domain ~frontends:{|[{"type":"fuse","uid":"no-such-user-x"}]|} "F"]);
  try_ "fuse uid out of range"
    (config [domain ~frontends:{|[{"type":"fuse","uid":"4294967296"}]|} "F"]);
  try_ "fuse unknown group"
    (config
       [domain ~frontends:{|[{"type":"fuse","gid":"no-such-group-x"}]|} "F"]);
  try_ "a frontend twice" (config [domain ~frontends:{|["fuse","fuse"]|} "F"]);
  try_ "no extensions" (config [domain ~extensions:None "F"]);
  try_ "unknown extension" (config [domain ~extensions:(Some {|["wifi"]|}) "F"]);
  try_ "an extension twice"
    (config [domain ~extensions:(Some {|["totp",{"type":"totp"}]|}) "F"]);
  try_ "unknown key in an extension"
    (config [domain ~extensions:(Some {|[{"type":"totp","x":1}]|}) "F"]);
  try_ "two extensions"
    (config [domain ~extensions:(Some {|["totp",{"type":"passwords"}]|}) "F"]);
  try_ "unused link"
    (config ~top:{|,"links":{"slow":{"maxRate":"1M"}}|} [domain "F"]);
  try_ "maxRate below minRate"
    (config ~top:{|,"uplink":{"minRate":"1M","maxRate":"512K"}|} [domain "F"]);
  try_ "wrong JSON type" (config [domain ~extra:{|,"readOnly":3|} "F"]);
  try_ "chunk size out of range"
    (config [domain ~extra:{|,"chunkSize":"1K"|} "F"]);
  p "\n== sizes\n";
  List.iter
    (fun s ->
      p "%-10S %s\n" s
        (match Config.parse_size s with
          | Some v -> string_of_int v
          | None -> "refused"))
    ["512K"; "8M"; "1G"; "1048576"; "8.0 MB"; "1.5 GiB"; "0"; "-1"; "x"]

(* frontends/http-proxy §A3: only the secret inherits across the shared
   listener; share links and read-only are each domain's own. *)
let () =
  p "\n== http-proxy bindings\n";
  let proxy opts =
    Printf.sprintf {|[{"type":"http-proxy","port":8443%s}]|} opts
  in
  let c =
    Config.of_string
      (config
         [
           domain
             ~frontends:
               (proxy (Printf.sprintf {|,"secret":"%s","shares":true|} secret))
             "F";
           domain ~frontends:(proxy {|,"readOnly":true|}) "G";
           domain ~frontends:(proxy "") "H";
         ])
  in
  match Tsync_http_proxy.Proxy_options.resolve c with
    | None -> p "no binding\n"
    | Some (_, bindings) ->
        List.iter
          (fun (b : Tsync_http_proxy.Proxy_options.binding) ->
            p "%s: secret inherited %b, shares %b, read-only %b\n"
              (Tsync_core.Domain_name.to_string b.domain.name)
              (b.secret = secret) b.shares b.read_only)
          bindings

let () =
  p "\n== a config other users can read (security-model §10.2)\n";
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-config-mode-%d" (Unix.getpid ()))
  in
  Tsync_core.Fs.rm_rf root;
  Unix.putenv "HOME" root;
  Unix.putenv "XDG_CONFIG_HOME" (Filename.concat root "config");
  let path = Paths.config_file () in
  Tsync_core.Fs.mkdir_p ~perm:0o700 (Filename.dirname path);
  let load ~interactive =
    match Paths.read_config ~interactive () with
      | Some _ -> "loaded"
      | None -> "absent"
      | exception Tsync_core.Fail.E f -> Tsync_core.Fail.kind_name f.kind
  in
  let mode () = (Unix.stat path).st_perm in
  p "no file: %s\n" (load ~interactive:false);
  Tsync_core.Fs.write_file_for_test path "{}";
  Unix.chmod path 0o644;
  let service = load ~interactive:false in
  p "mode 644, a service: %s, left at %o\n" service (mode ());
  let terminal = load ~interactive:true in
  p "mode 644, at a terminal: %s, now %o\n" terminal (mode ());
  p "mode 600, a service: %s\n" (load ~interactive:false);
  Tsync_core.Fs.rm_rf root

let () =
  p "\n== path arguments (07 §5.2)\n";
  let c =
    Config.of_string
      {|{"domains":[
          {"name":"media","symlinks":"keep","versioning":true,
           "extensions":[],"frontends":[{"type":"fuse","mountPoint":"/mnt/media/"}],
           "backends":[{"type":"local","name":"a","role":"main","path":"/srv/a"}]},
          {"name":"media:raw","symlinks":"keep","versioning":true,"extensions":[],"frontends":["http-proxy"],
           "backends":[{"type":"local","name":"a","role":"main","path":"/srv/b"}]}]}|}
  in
  let domain = Option.value ~default:"(resolved)" in
  List.iter
    (fun token ->
      p "%-24s as a side: %s; in a domain: %s\n" token
        (match Domain_path.parse c token with
          | In_domain { domain = d; rel } -> domain d ^ " " ^ "[" ^ rel ^ "]"
          | Local path when Filename.dirname path = Sys.getcwd () ->
              "local <cwd>/" ^ Filename.basename path
          | Local path -> "local " ^ path)
        (match Domain_path.in_domain c token with
          | Ok (d, rel) -> domain d ^ " [" ^ rel ^ "]"
          | Error e -> "refused: " ^ e))
    [
      "media:/a//b/";
      "media:a";
      "media:";
      "media:raw:x";
      ":x/y";
      "other:x";
      "/mnt/media";
      "/mnt/media/a/b";
      "/mnt/mediaX/a";
      "/etc/passwd";
    ];
  p "a relative token in a domain: [%s]\n"
    (match Domain_path.in_domain c "a//b/" with
      | Ok (None, rel) -> rel
      | _ -> "?");
  List.iter
    (fun (name, named) ->
      p "--domain %s with %s: %s\n"
        (Option.value ~default:"-" name)
        (String.concat ", " (List.map (Option.value ~default:"-") named))
        (match Domain_path.agree ?name named with
          | Ok d -> Option.value ~default:"(resolved)" d
          | Error e -> "refused: " ^ e))
    [
      (None, [None; None]);
      (None, [Some "media"; None; Some "media"]);
      (Some "media", [Some "media"]);
      (Some "media", [Some "other"]);
      (None, [Some "media"; Some "other"]);
    ]

let () =
  p "\n== extensions in force (05 §2.1 rule 5)\n";
  let stated extensions : Tsync_store.Store.domain_settings =
    {
      chunk = 4096;
      symlinks = `Keep;
      lease = 30.;
      quarantine = 300.;
      settle = 600.;
      entry_commands = 64;
      projector = None;
      extensions;
      vault_lock = Tsync_core.Vault_lock.none;
    }
  in
  let one extensions =
    List.hd
      (Config.of_string
         (config [domain ~frontends:{|["android"]|} ~extensions "F"]))
        .Config.domains
  in
  List.iter
    (fun (what, extensions, main) ->
      p "  %-44s [%s]\n" what
        (String.concat "," (Config.extensions_in_force (one extensions) main)))
    [
      ("none configured, nothing stated", None, None);
      ("none configured, totp stated", None, Some (stated ["totp"]));
      ( "none configured, an unknown one stated too",
        None,
        Some (stated ["totp"; "wifi"]) );
      ("[] configured, totp stated", Some "[]", Some (stated ["totp"]));
      ( "passwords configured, totp stated",
        Some {|["passwords"]|},
        Some (stated ["totp"]) );
    ]
