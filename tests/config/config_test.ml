open Tsync_config

let p fmt = Printf.printf fmt
let secret = String.make 40 'x'

let domain ?(extra = "")
    ?(backends =
      {|[{"type":"local","name":"disk","role":"main","path":"/srv/d"}]|})
    ?(frontends = {|["fuse"]|}) name =
  Printf.sprintf
    {|{"name":%S,"symlinks":"keep","versioning":true,"backends":%s,"frontends":%s%s}|}
    name backends frontends extra

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
                  Printf.sprintf "%s ro=%b backends=%s"
                    (Tsync_core.Domain_name.to_string d.name)
                    d.read_only
                    (String.concat ","
                       (List.map
                          (fun (b : Config.backend) ->
                            b.bname ^ ":"
                            ^ Tsync_store.Composite.role_to_string b.role)
                          d.backends)))
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
    {|{"domains":[{"name":"F","symlinks":"keep","backends":[{"type":"local","name":"d","role":"main","path":"/d"}],"frontends":["fuse"]}]}|};
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
  try_ "fuse unknown group"
    (config
       [domain ~frontends:{|[{"type":"fuse","gid":"no-such-group-x"}]|} "F"]);
  try_ "a frontend twice" (config [domain ~frontends:{|["fuse","fuse"]|} "F"]);
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
