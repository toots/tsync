type paths = {
  cache_root : string;
  socket_path : string;
  data_dir : string;
  config_path : string;
}

let implementation = "file_provider"

let default_paths () =
  let home = Sys.getenv "HOME" in
  let app_group =
    Filename.concat home "Library/Group Containers/group.com.toots.tsync"
  in
  let data_dir = Filename.concat app_group "tsync" in
  {
    cache_root = Filename.concat data_dir "cache";
    socket_path = Filename.concat data_dir "tsync.sock";
    data_dir;
    config_path = Filename.concat app_group "config.json";
  }

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

module Make (C : Conf.S) = File_provider.Make (C)
