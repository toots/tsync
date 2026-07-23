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
   one runs in this process. *)
let start bindings = Frontend.run_forked mount_binding bindings

let register () =
  Frontend.register implementation
    (module struct
      let is_local = is_local
      let start = start
    end : Frontend.S)
