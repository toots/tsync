type paths = {
  cache_root : string;
  socket_path : string;
  data_dir : string;
  config_path : string;
}

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

(* All domains share the same socket; the daemon routes by domain prefix. *)
let domain_socket_path paths _domain_name = paths.socket_path
