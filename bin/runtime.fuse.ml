type paths = {
  cache_root : string;
  socket_path : string;
  data_dir : string;
  config_path : string;
}

let implementation = "fuse"

let default_paths () =
  let home = Sys.getenv "HOME" in
  let cache_base =
    match Sys.getenv_opt "XDG_CACHE_HOME" with
      | Some d -> d
      | None -> Filename.concat home ".cache"
  in
  let data_base =
    match Sys.getenv_opt "XDG_DATA_HOME" with
      | Some d -> d
      | None -> Filename.concat home ".local/share"
  in
  let config_base =
    match Sys.getenv_opt "XDG_CONFIG_HOME" with
      | Some d -> d
      | None -> Filename.concat home ".config"
  in
  let data_dir = Filename.concat data_base "tsync" in
  {
    cache_root = Filename.concat cache_base "tsync";
    socket_path = Filename.concat data_dir "tsync.sock";
    data_dir;
    config_path = Filename.concat config_base "tsync/config.json";
  }

let pre_start ~mount_point =
  ignore
    (Sys.command
       (Printf.sprintf "fusermount3 -uz %s 2>/dev/null"
          (Filename.quote mount_point)))

let is_local ~cache_root ~domain_name ~domain_prefix key =
  Sys.file_exists (Local.cache_path ~cache_root ~domain_name ~domain_prefix key)

module Make (C : Conf.S) = Fuse_fs.Make (C)
