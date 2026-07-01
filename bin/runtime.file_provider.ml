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

module Make (C : Conf.S) = File_provider.Make (C)
