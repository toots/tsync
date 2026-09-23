let implementation = "fuse"
let availability = Checkout.availability

(* Clear a stale mount left by a previous crash, then (re)create the mount point. *)
let prepare_mount_point mount_point =
  ignore
    (Sys.command
       (Printf.sprintf "fusermount3 -uz %s 2>/dev/null"
          (Filename.quote mount_point)));
  Io_lwt.Fs.mkdir_p_sync mount_point

(* The value lands in FUSE's comma-separated [-o] list, so a typo with a comma
   or an [=] fails here, naming the field, rather than as a mount error. *)
let mount_subtype = function
  | None | Some "" -> "sshfs"
  | Some subtype ->
      String.iter
        (function
          | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> ()
          | _ ->
              failwith (Printf.sprintf "fuse: invalid mountSubtype %S" subtype))
        subtype;
      subtype

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
  let subtype =
    mount_subtype (List.assoc_opt "mountSubtype" b.Frontend.options)
  in
  prepare_mount_point b.Frontend.mount_point;
  let module D = (val sv.Frontend.domain : Domain_engine.Domain) in
  let module R = Fuse_fs.Make (C) (D) in
  R.mount ~allow_other ~subtype b.Frontend.mount_point

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
      {
        name = "mountSubtype";
        label =
          "Filesystem type the mount reports, as fuse.TYPE (sshfs: file \
           managers treat it as remote and do not download files to thumbnail \
           them; tsync: its own name)";
        typ = `String;
        default = Some "sshfs";
        secret = false;
      };
    ]

let register () =
  Frontend.register ~spec implementation
    (module struct
      let availability = availability
      let tree = `Replicated

      let serving =
        Frontend.Daemon { topology; listens = Some `Domain_socket; start }
    end : Frontend.S)
