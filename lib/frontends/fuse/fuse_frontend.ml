let implementation = "fuse"

let pre_start ~mount_point =
  ignore
    (Sys.command
       (Printf.sprintf "fusermount3 -uz %s 2>/dev/null"
          (Filename.quote mount_point)))

let is_local ~cache_root ~domain_name ~domain_prefix key =
  Sys.file_exists (Local.cache_path ~cache_root ~domain_name ~domain_prefix key)

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

let () =
  Frontend.register implementation
    (module struct
      let implementation = implementation
      let pre_start = pre_start
      let is_local = is_local
      let start = start
    end : Frontend.S)
