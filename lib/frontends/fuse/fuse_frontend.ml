let implementation = "fuse"

let is_local ~cache_root ~domain_name ~domain_prefix key =
  Sys.file_exists (Local.cache_path ~cache_root ~domain_name ~domain_prefix key)

let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

(* Clear a stale mount left by a previous crash, then (re)create the mount point. *)
let prepare_mount_point mount_point =
  ignore
    (Sys.command
       (Printf.sprintf "fusermount3 -uz %s 2>/dev/null"
          (Filename.quote mount_point)));
  mkdir_p mount_point

let mount_binding (b : Frontend.binding) =
  prepare_mount_point b.Frontend.mount_point;
  let module C = (val b.Frontend.conf : Conf.S) in
  let module R = Fuse_fs.Make (C) in
  R.mount b.Frontend.mount_point

(* Each domain runs FUSE in its own child process (fuse's mount blocks); the last
   one runs in this process. On shutdown, SIGTERM and reap the children. *)
let start bindings =
  let rec go child_pids = function
    | [] -> List.rev child_pids
    | [b] ->
        mount_binding b;
        List.rev child_pids
    | b :: rest ->
        let pid = Unix.fork () in
        if pid = 0 then begin
          mount_binding b;
          exit 0
        end;
        go (pid :: child_pids) rest
  in
  let child_pids = go [] bindings in
  List.iter
    (fun pid ->
      (try Unix.kill pid Sys.sigterm with _ -> ());
      try ignore (Unix.waitpid [] pid) with _ -> ())
    child_pids

let register () =
  Frontend.register implementation
    (module struct
      let implementation = implementation
      let is_local = is_local
      let start = start
    end : Frontend.S)
