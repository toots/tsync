let implementation = "file_provider"
let pre_start ~mount_point:_ = ()

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

let start ~confs ~mount_fn:_ =
  let paths = Runtime.default_paths () in
  File_provider.start ~confs ~socket_path:paths.Runtime.socket_path

let () =
  Frontend.register implementation
    (module struct
      let implementation = implementation
      let pre_start = pre_start
      let is_local = is_local
      let start = start
    end : Frontend.S)
