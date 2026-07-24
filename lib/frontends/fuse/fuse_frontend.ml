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
  (* Leaf process (post-fork): safe to initialize Lwt now. *)
  Frontend.cap_blocking_pool ();
  let module C = (val b.Frontend.conf : Conf.S) in
  (* Each domain is its own process; tag its log lines with the domain name. *)
  Log.set_prefix (Printf.sprintf "[%s] " C.domain_name);
  (* [allowOther] frontend option → FUSE allow_other, so a service running as
     another user (e.g. a media server) can read the mount. *)
  let allow_other =
    match List.assoc_opt "allowOther" b.Frontend.options with
      | Some ("true" | "1") -> true
      | _ -> false
  in
  prepare_mount_point b.Frontend.mount_point;
  let module R = Fuse_fs.Make (C) in
  R.mount ~allow_other b.Frontend.mount_point

(* Each domain runs FUSE in its own child process (fuse's mount blocks); the last
   one runs in this process. *)
let start bindings = Frontend.run_forked mount_binding bindings

let spec =
  Frontend.
    [
      {
        name = "allowOther";
        label = "Allow other users to access the mount (media servers, etc.)";
        typ = `Bool;
        default = Some "false";
        secret = false;
      };
    ]

let register () =
  Frontend.register ~spec implementation
    (module struct
      let is_local = is_local
      let start = start
    end : Frontend.S)
