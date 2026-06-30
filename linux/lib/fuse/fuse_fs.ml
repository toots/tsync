type context = Context.t

(* ── Auto-evict ──────────────────────────────────────────────────────────── *)

let auto_evict = ref (Sys.file_exists (Ipc.auto_evict_path ()))

(* ── The FUSE kernel creates .fuse_hidden* files when renaming a file that
   has open file descriptors. These are kernel-internal; never mirror to S3. *)
let is_fuse_hidden path =
  let basename = Filename.basename path in
  let prefix = ".fuse_hidden" in
  String.length basename >= String.length prefix
  && String.sub basename 0 (String.length prefix) = prefix

(* ── Exception guard ─────────────────────────────────────────────────────── *)

let guard op path f =
  try f () with
    | Unix.Unix_error _ as e -> raise e
    | exn ->
        Log.err "fuse %s %s: unexpected exception: %s" op path
          (Printexc.to_string exn);
        raise (Unix.Unix_error (Unix.EIO, op, path))

(* ── Journal WAL helpers ─────────────────────────────────────────────────── *)

let pending_version_key : string option ref = ref None
let pending_version_mutex = Mutex.create ()

let set_pending_version ek =
  Mutex.lock pending_version_mutex;
  (match !pending_version_key with
    | Some prev when prev >= ek -> ()
    | _ -> pending_version_key := Some ek);
  Mutex.unlock pending_version_mutex

let drain_pending_version () =
  Mutex.lock pending_version_mutex;
  let v = !pending_version_key in
  pending_version_key := None;
  Mutex.unlock pending_version_mutex;
  v

(* ── FUSE operations ─────────────────────────────────────────────────────── *)

let make_operations ctx =
  let open Fuse in
  let hidden = Hidden_ops.make ctx in
  let real = Internal_ops.make ~ctx in
  let dispatch path = if is_fuse_hidden path then hidden else real in
  let entry_of_name name =
    {
      entry_name = name;
      entry_stats = None;
      entry_offset = None;
      entry_flags = { fill_dir_plus = false };
    }
  in
  {
    default_operations with
    init = (fun () -> ());
    getattr =
      (fun path _fi ->
        let key = Context.fuse_to_key ctx path in
        match File.stat (File.make ~store:ctx.files ~key) with
          | Some st -> st
          | None -> raise (Unix.Unix_error (Unix.ENOENT, "getattr", path)));
    readdir =
      (fun path _offset _fi _flags ->
        let key = Context.fuse_to_dir_prefix ctx path in
        let entries = File.list_dir (File.make ~store:ctx.files ~key) in
        List.map entry_of_name ("." :: ".." :: entries));
    mknod =
      (fun path mode ->
        guard "mknod" path (fun () -> (dispatch path).mknod path mode));
    fopen =
      (fun path fi ->
        guard "fopen" path (fun () -> (dispatch path).fopen path fi));
    read =
      (fun path buf offset fi ->
        guard "read" path (fun () -> (dispatch path).read path buf offset fi));
    write =
      (fun path buf offset fi ->
        guard "write" path (fun () -> (dispatch path).write path buf offset fi));
    release =
      (fun path fi ->
        guard "release" path (fun () -> (dispatch path).release path fi));
    unlink =
      (fun path -> guard "unlink" path (fun () -> (dispatch path).unlink path));
    mkdir =
      (fun path _mode ->
        guard "mkdir" path (fun () ->
            let key = Context.fuse_to_dir_prefix ctx path in
            File.mkdir (File.make ~store:ctx.files ~key)));
    rmdir =
      (fun path ->
        guard "rmdir" path (fun () ->
            let key = Context.fuse_to_dir_prefix ctx path in
            File.rmdir (File.make ~store:ctx.files ~key)));
    rename =
      (fun src dst flags ->
        guard "rename" src (fun () ->
            let is_hidden = is_fuse_hidden dst in
            (if is_hidden then hidden else real).rename src dst flags;
            if is_hidden then real.unlink src));
    truncate =
      (fun path size fi ->
        guard "truncate" path (fun () -> (dispatch path).truncate path size fi));
    statfs =
      (fun _path ->
        Unix_util.
          {
            f_bsize = 4096L;
            f_frsize = 4096L;
            f_blocks = Int64.of_int max_int;
            f_bfree = Int64.of_int max_int;
            f_bavail = Int64.of_int max_int;
            f_files = Int64.of_int max_int;
            f_ffree = Int64.of_int max_int;
            f_favail = Int64.of_int max_int;
            f_fsid = 0L;
            f_flag = 0L;
            f_namemax = 255L;
          });
    utimens = (fun _path _atime _mtime _fi -> ());
  }

(* ── IPC handler ─────────────────────────────────────────────────────────── *)

let ipc_handler ctx line =
  let cmd, arg = Ipc.split_cmd (String.trim line) in
  let key_of_path path =
    let path =
      if String.length path >= 2 && path.[0] = '~' && path.[1] = '/' then
        Sys.getenv "HOME" ^ String.sub path 1 (String.length path - 1)
      else path
    in
    if
      String.length path > String.length ctx.Context.mount_point
      && String.sub path 0 (String.length ctx.mount_point) = ctx.mount_point
    then
      Context.fuse_to_key ctx
        (String.sub path
           (String.length ctx.mount_point)
           (String.length path - String.length ctx.mount_point))
    else Context.fuse_to_key ctx path
  in
  match cmd with
    | "EVICT" ->
        let key = key_of_path arg in
        let lp = File.local_path (File.make ~store:ctx.files ~key) in
        if Sys.file_exists lp && Sys.is_directory lp then begin
          let root = Local.cache_root ctx.domain_name in
          let rec walk dir =
            Array.iter
              (fun name ->
                let p = Filename.concat dir name in
                if Sys.is_directory p then walk p
                else begin
                  let rel =
                    String.sub p
                      (String.length root + 1)
                      (String.length p - String.length root - 1)
                  in
                  File.request_evict
                    (File.make ~store:ctx.files ~key:(ctx.domain_prefix ^ rel))
                end)
              (try Sys.readdir dir with _ -> [||])
          in
          walk lp
        end
        else File.request_evict (File.make ~store:ctx.files ~key);
        "OK"
    | "RESTORE" ->
        let key = key_of_path arg in
        let lp = File.local_path (File.make ~store:ctx.files ~key) in
        let is_dir =
          (String.length key > 0 && key.[String.length key - 1] = '/')
          || (Sys.file_exists lp && Sys.is_directory lp)
        in
        if is_dir then begin
          let prefix =
            if String.length key > 0 && key.[String.length key - 1] = '/' then
              key
            else key ^ "/"
          in
          let files = File_store.list_all_files ctx.store ~prefix in
          List.iter
            (fun (e : S3_client.file_entry) ->
              try File.ensure_cached (File.make ~store:ctx.files ~key:e.key)
              with exn ->
                Log.err "restore %s: %s" e.key (Printexc.to_string exn))
            files;
          "OK"
        end
        else (
          try
            File.ensure_cached (File.make ~store:ctx.files ~key);
            "OK"
          with exn -> "ERROR " ^ Printexc.to_string exn)
    | "STATUS" ->
        Printf.sprintf {|STATUS {"mount":"%s","domain":"%s","running":true}|}
          ctx.mount_point ctx.domain_name
    | "STOP" ->
        let _ =
          Thread.create
            (fun () ->
              Unix.sleepf 0.1;
              ignore
                (Sys.command
                   (Printf.sprintf "fusermount3 -u %s" ctx.mount_point)))
            ()
        in
        "STOP"
    | "AUTO_EVICT" -> (
        match arg with
          | "on" ->
              auto_evict := true;
              (try close_out (open_out (Ipc.auto_evict_path ())) with _ -> ());
              "OK"
          | "off" ->
              auto_evict := false;
              (try Unix.unlink (Ipc.auto_evict_path ())
               with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
              "OK"
          | "status" -> if !auto_evict then "on" else "off"
          | _ -> "ERROR expected on|off|status")
    | "FULL_RESYNC" ->
        let root = Local.cache_root ctx.Context.domain_name in
        let rec walk dir =
          if Sys.file_exists dir then
            Array.iter
              (fun name ->
                let p = Filename.concat dir name in
                if Sys.is_directory p then walk p
                else (try Unix.unlink p with _ -> ()))
              (try Sys.readdir dir with _ -> [||])
        in
        walk root;
        "OK"
    | _ -> "ERROR unknown command"

(* ── Main mount ─────────────────────────────────────────────────────────── *)

let mount ctx argv =
  let _ipc_thread = Thread.create (fun () -> Ipc.serve (ipc_handler ctx)) () in
  let _version_flusher =
    Thread.create
      (fun () ->
        while true do
          Unix.sleepf 2.0;
          match drain_pending_version () with
            | None -> ()
            | Some ek -> (
                try File_store.bump_version ctx.store ek
                with exn ->
                  Log.err "bump_version: %s" (Printexc.to_string exn))
        done)
      ()
  in
  Fuse.main ~loop_mode:Fuse.Single_threaded argv (make_operations ctx)

let path_to_key ctx abs_path =
  if
    String.length abs_path > String.length ctx.Context.mount_point
    && String.sub abs_path 0 (String.length ctx.mount_point) = ctx.mount_point
  then
    Context.fuse_to_key ctx
      (String.sub abs_path
         (String.length ctx.mount_point)
         (String.length abs_path - String.length ctx.mount_point))
  else Context.fuse_to_key ctx abs_path

let key_to_abs_path ctx key =
  let rel =
    let dp_len = String.length ctx.Context.domain_prefix in
    if String.length key >= dp_len then
      "/" ^ String.sub key dp_len (String.length key - dp_len)
    else key
  in
  ctx.mount_point ^ rel
