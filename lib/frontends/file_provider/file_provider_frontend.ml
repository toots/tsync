let implementation = "file_provider"

let is_local ~cache_root:_ ~domain_name ~domain_prefix key =
  let pfx = String.length domain_prefix in
  let rel =
    if String.length key > pfx then String.sub key pfx (String.length key - pfx)
    else key
  in
  let normalized =
    String.concat "-"
      (String.split_on_char ' ' (String.lowercase_ascii domain_name))
  in
  let cloud_root = Filename.concat (Sys.getenv "HOME") "Library/CloudStorage" in
  let domain_dir = Filename.concat cloud_root ("TsyncApp-" ^ normalized) in
  let p = Filename.concat domain_dir rel in
  Sys.file_exists p && not (File_provider.is_dataless p)

(* All domains share one IPC socket; the daemon routes by domain prefix. *)
let start bindings =
  (* Leaf process (post-fork): safe to initialize Lwt now. *)
  Frontend.cap_blocking_pool ();
  let paths = Runtime.default_paths () in
  let confs =
    List.map (fun (b : Frontend.binding) -> b.Frontend.conf) bindings
  in
  File_provider.start ~confs ~socket_path:paths.Runtime.socket_path

let register () =
  Frontend.register implementation
    (module struct
      let is_local = is_local
      let start = start
    end : Frontend.S)
