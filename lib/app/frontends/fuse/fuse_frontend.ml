let implementation = "fuse"
let is_local = Checkout.is_local

(* Clear a stale mount left by a previous crash, then (re)create the mount point. *)
let prepare_mount_point mount_point =
  ignore
    (Sys.command
       (Printf.sprintf "fusermount3 -uz %s 2>/dev/null"
          (Filename.quote mount_point)));
  Io_lwt.Fs.mkdir_p_sync mount_point

let mount_binding (sv : Frontend.served) =
  let b = sv.Frontend.binding in
  let module C = (val b.Frontend.conf : Conf_lwt.S) in
  (* Each domain is its own process; tag its log lines with the domain name. *)
  Log.set_prefix (Printf.sprintf "[%s] " C.domain_name);
  (* FUSE allow_other, so a service running as another user can read the
     mount. *)
  let allow_other =
    Field_spec.bool ~default:false
      (List.assoc_opt "allowOther" b.Frontend.options)
  in
  prepare_mount_point b.Frontend.mount_point;
  let module D = (val sv.Frontend.domain : Domain_engine.Domain) in
  let module R = Fuse_fs.Make (C) (D) in
  R.mount ~allow_other b.Frontend.mount_point

(* FUSE's mount blocks, so the launcher gives each domain its own process, and
   hands this exactly one. Serving a second would mount it only once the first
   came down, which is silence rather than an answer. *)
let topology = `Process_per_binding

let start = function
  | [b] -> mount_binding b
  | bindings ->
      failwith
        (Printf.sprintf "fuse: expected one domain per process, got %d"
           (List.length bindings))

let spec =
  Field_spec.
    [
      {
        name = "mountPoint";
        label = "Directory to mount the domain at (blank: ~/tsync/DOMAIN)";
        typ = `String;
        default = Some "";
        secret = false;
      };
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
      let topology = topology
      let listens = Some `Domain_socket
      let start = start
    end : Frontend.S)
