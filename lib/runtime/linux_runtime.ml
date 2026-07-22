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

(* Each FUSE domain runs in its own child process, so each needs its own socket. *)
let domain_socket_path paths domain_name =
  Filename.concat paths.data_dir ("tsync-" ^ domain_name ^ ".sock")

let is_local ~cache_root ~domain_name ~domain_prefix key =
  Sys.file_exists (Local.cache_path ~cache_root ~domain_name ~domain_prefix key)

module Make (C : Conf.S) = Fuse_fs.Make (C)

let start ~confs ~mount_fn =
  let rec go child_pids = function
    | [] -> List.rev child_pids
    | [conf] ->
        let module C = (val conf : Conf.S) in
        let module R = Fuse_fs.Make (C) in
        R.mount (mount_fn C.domain_name);
        List.rev child_pids
    | conf :: rest ->
        let module C = (val conf : Conf.S) in
        let module R = Fuse_fs.Make (C) in
        let pid = Unix.fork () in
        if pid = 0 then begin
          R.mount (mount_fn C.domain_name);
          exit 0
        end;
        go (pid :: child_pids) rest
  in
  let child_pids = go [] confs in
  List.iter
    (fun pid ->
      (try Unix.kill pid Sys.sigterm with _ -> ());
      try ignore (Unix.waitpid [] pid) with _ -> ())
    child_pids
