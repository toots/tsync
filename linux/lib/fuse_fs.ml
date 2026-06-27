type context = {
  store : S3_store.t;
  domain_name : string;
  domain_prefix : string;
  mount_point : string;
}

(* ── Path helpers ────────────────────────────────────────────────────────── *)

(* "/subdir/file.txt" → "prefix/domain/subdir/file.txt" *)
let fuse_to_key ctx path =
  let rel =
    if path = "/" then "" else String.sub path 1 (String.length path - 1)
  in
  ctx.domain_prefix ^ rel

(* "/subdir" or "/subdir/" → "prefix/domain/subdir/" *)
let fuse_to_dir_prefix ctx path =
  let key = fuse_to_key ctx path in
  if key = ctx.domain_prefix then key
  else if String.length key > 0 && key.[String.length key - 1] = '/' then key
  else key ^ "/"

(* "prefix/domain/file.txt" → "/file.txt" (for IPC path argument) *)
let key_to_fuse ctx key =
  let dp_len = String.length ctx.domain_prefix in
  if String.length key >= dp_len then
    "/" ^ String.sub key dp_len (String.length key - dp_len)
  else key

(* "prefix/domain/file.txt" → "file.txt" (domain-relative, for journal) *)
let rel_key ctx full_key =
  let dp_len = String.length ctx.domain_prefix in
  if String.length full_key > dp_len then
    String.sub full_key dp_len (String.length full_key - dp_len)
  else full_key

(* ── Metadata cache ──────────────────────────────────────────────────────── *)

let meta_cache : (string, Unix.LargeFile.stats) Hashtbl.t = Hashtbl.create 256
let meta_mutex = Mutex.create ()

let cache_put key stats =
  Mutex.lock meta_mutex;
  Hashtbl.replace meta_cache key stats;
  Mutex.unlock meta_mutex

let cache_get key =
  Mutex.lock meta_mutex;
  let r = Hashtbl.find_opt meta_cache key in
  Mutex.unlock meta_mutex;
  r

let cache_invalidate key =
  Mutex.lock meta_mutex;
  Hashtbl.remove meta_cache key;
  Mutex.unlock meta_mutex

(* ── Stat helpers ────────────────────────────────────────────────────────── *)

let dir_stat () =
  let now = Unix.gettimeofday () in
  Unix.LargeFile.
    {
      st_dev = 0;
      st_ino = 0;
      st_kind = Unix.S_DIR;
      st_perm = 0o755;
      st_nlink = 2;
      st_uid = Unix.getuid ();
      st_gid = Unix.getgid ();
      st_rdev = 0;
      st_size = 0L;
      st_atime = now;
      st_mtime = now;
      st_ctime = now;
    }

let file_stat size mtime =
  Unix.LargeFile.
    {
      st_dev = 0;
      st_ino = 0;
      st_kind = Unix.S_REG;
      st_perm = 0o644;
      st_nlink = 1;
      st_uid = Unix.getuid ();
      st_gid = Unix.getgid ();
      st_rdev = 0;
      st_size = Int64.of_int size;
      st_atime = mtime;
      st_mtime = mtime;
      st_ctime = mtime;
    }

let stat_of_entry (e : S3_client.file_entry) = file_stat e.size e.last_modified

(* ── Cache helpers ───────────────────────────────────────────────────────── *)

let is_cached ctx key =
  Cache.is_cached ~domain_name:ctx.domain_name ~domain_prefix:ctx.domain_prefix
    key

let local_path ctx key =
  Cache.cache_path ~domain_name:ctx.domain_name ~domain_prefix:ctx.domain_prefix
    key

let ensure_cached ctx key =
  if not (is_cached ctx key) then begin
    let dst = local_path ctx key in
    S3_store.download ctx.store ~key ~dst_path:dst
  end

(* ── Auto-evict ──────────────────────────────────────────────────────────── *)

let auto_evict = ref (Sys.file_exists (Ipc.auto_evict_path ()))

(* ── Dirty tracking for write→release ────────────────────────────────────── *)

let dirty : (string, bool) Hashtbl.t = Hashtbl.create 64
let dirty_mutex = Mutex.create ()

let mark_dirty key =
  Mutex.lock dirty_mutex;
  Hashtbl.replace dirty key true;
  Mutex.unlock dirty_mutex

let is_dirty key =
  Mutex.lock dirty_mutex;
  let r = Hashtbl.mem dirty key in
  Mutex.unlock dirty_mutex;
  r

let clear_dirty key =
  Mutex.lock dirty_mutex;
  Hashtbl.remove dirty key;
  Mutex.unlock dirty_mutex

(* ── Exception guard ─────────────────────────────────────────────────────── *)

(* Catch non-Unix exceptions (which ocamlfuse would silently map to ERANGE),
   log them, and re-raise as EIO so the error is meaningful and visible. *)
let guard op path f =
  try f ()
  with
  | Unix.Unix_error _ as e -> raise e
  | exn ->
      Log.err "fuse %s %s: unexpected exception: %s" op path
        (Printexc.to_string exn);
      raise (Unix.Unix_error (Unix.EIO, op, path))

(* ── Journal WAL helpers ─────────────────────────────────────────────────── *)

(* Latest journal entry key and keys pending eviction — both drained by the 2s flusher. *)
let pending_version_key : string option ref = ref None
let pending_evictions : string Queue.t = Queue.create ()
let pending_version_mutex = Mutex.create ()

let set_pending_version ek =
  Mutex.lock pending_version_mutex;
  (* Keep the lexicographically larger key (later timestamp wins) *)
  (match !pending_version_key with
    | Some prev when prev >= ek -> ()
    | _ -> pending_version_key := Some ek);
  Mutex.unlock pending_version_mutex

let queue_eviction key =
  Mutex.lock pending_version_mutex;
  Queue.push key pending_evictions;
  Mutex.unlock pending_version_mutex

let drain_pending () =
  Mutex.lock pending_version_mutex;
  let v = !pending_version_key in
  pending_version_key := None;
  let evictions = Queue.fold (fun acc k -> k :: acc) [] pending_evictions in
  Queue.clear pending_evictions;
  Mutex.unlock pending_version_mutex;
  (v, evictions)

let fire_journal ctx ~entry_key ops =
  ignore
    (Thread.create
       (fun () ->
         (try
            ignore (S3_store.write_journal_entry ~entry_key ops ctx.store);
            set_pending_version entry_key
          with exn ->
            Log.err "write_journal_entry: %s" (Printexc.to_string exn));
         Journal.delete_local_pending ~entry_key)
       ())

(* ── Cache walk (for FULL_RESYNC) ────────────────────────────────────────── *)

let walk_cache_dir ctx f =
  let root = Cache.cache_root ctx.domain_name in
  let rec walk dir =
    if Sys.file_exists dir then
      Array.iter
        (fun name ->
          let path = Filename.concat dir name in
          if Sys.is_directory path then walk path else f path)
        (try Sys.readdir dir with _ -> [||])
  in
  walk root

(* ── FUSE operations ─────────────────────────────────────────────────────── *)

let make_operations ctx =
  let open Fuse.Fuse_compat in
  {
    default_operations with
    getattr =
      (fun path ->
        if path = "/" then dir_stat ()
        else begin
          let key = fuse_to_key ctx path in
          match cache_get key with
            | Some st -> st
            | None ->
                (* Check local cache first (already downloaded) *)
                if is_cached ctx key then
                  Unix.LargeFile.stat (local_path ctx key)
                else begin
                  (* HEAD on S3 as file, then as directory; stat_file resolves manifest size *)
                    match S3_store.stat_file ctx.store ~key with
                    | Some c ->
                        let st = stat_of_entry c in
                        cache_put key st;
                        st
                    | None -> (
                        let dir_key = key ^ "/" in
                        match S3_store.head_opt ctx.store ~key:dir_key with
                          | Some _ -> dir_stat ()
                          | None ->
                              raise
                                (Unix.Unix_error (Unix.ENOENT, "getattr", path))
                        )
                end
        end);
    readdir =
      (fun path _offset ->
        (* ponytail: always live from S3; add a short-TTL directory listing cache when list latency matters *)
        let prefix = fuse_to_dir_prefix ctx path in
        let files, subdirs = S3_store.list_directory ctx.store ~prefix in
        List.iter
          (fun (e : S3_client.file_entry) -> cache_put e.key (stat_of_entry e))
          files;
        let file_names =
          List.map
            (fun (e : S3_client.file_entry) -> Filename.basename e.key)
            files
        in
        ("." :: ".." :: file_names) @ subdirs);
    mknod =
      (fun path _mode ->
        let key = fuse_to_key ctx path in
        let lp = local_path ctx key in
        (try Cache.ensure_parent_dir lp
         with exn ->
           Log.err "mknod ensure_parent_dir %s: %s" lp (Printexc.to_string exn);
           raise (Unix.Unix_error (Unix.EIO, "mknod", path)));
        (try close_out (open_out_bin lp)
         with exn ->
           Log.err "mknod open %s: %s" lp (Printexc.to_string exn);
           raise (Unix.Unix_error (Unix.EIO, "mknod", path)));
        mark_dirty key);
    fopen =
      (fun path flags ->
        guard "fopen" path (fun () ->
          let key = fuse_to_key ctx path in
          let creating = List.mem Unix.O_CREAT flags in
          if creating && not (is_cached ctx key) then begin
            (* New file: create empty local placeholder *)
            let lp = local_path ctx key in
            Cache.ensure_parent_dir lp;
            close_out (open_out_bin lp)
          end
          else if not (is_cached ctx key) then ensure_cached ctx key;
          None));
    read =
      (fun path buf offset _size ->
        guard "read" path (fun () ->
          let key = fuse_to_key ctx path in
          ensure_cached ctx key;
          let lp = local_path ctx key in
          let size = Bigarray.Array1.dim buf in
          let tmp = Bytes.create size in
          let fd = Unix.openfile lp [Unix.O_RDONLY] 0 in
          ignore (Unix.lseek fd (Int64.to_int offset) Unix.SEEK_SET);
          let n = Unix.read fd tmp 0 size in
          Unix.close fd;
          for i = 0 to n - 1 do
            buf.{i} <- Bytes.get tmp i
          done;
          n));
    write =
      (fun path buf offset _size ->
        guard "write" path (fun () ->
          let key = fuse_to_key ctx path in
          let lp = local_path ctx key in
          Cache.ensure_parent_dir lp;
          let size = Bigarray.Array1.dim buf in
          let tmp = Bytes.create size in
          for i = 0 to size - 1 do
            Bytes.set tmp i buf.{i}
          done;
          let fd = Unix.openfile lp [Unix.O_WRONLY; Unix.O_CREAT] 0o644 in
          ignore (Unix.lseek fd (Int64.to_int offset) Unix.SEEK_SET);
          let written = ref 0 in
          while !written < size do
            written := !written + Unix.write fd tmp !written (size - !written)
          done;
          Unix.close fd;
          mark_dirty key;
          size));
    release =
      (fun path flags _fd ->
        guard "release" path (fun () ->
          let key = fuse_to_key ctx path in
          let writing =
            List.mem Unix.O_WRONLY flags
            || List.mem Unix.O_RDWR flags || is_dirty key
          in
          if writing then begin
            Log.debug "release %s: uploading" path;
            let lp = local_path ctx key in
            let ek = Journal.entry_key () in
            let size =
              try (Unix.LargeFile.stat lp).Unix.LargeFile.st_size
              with _ -> 0L
            in
            let ops = [ `Put (rel_key ctx key, size) ] in
            Journal.write_local_pending ~entry_key:ek ops;
            let uploaded =
              try S3_store.upload ctx.store ~key ~src_path:lp; true
              with exn ->
                Log.err "upload %s: %s" key (Printexc.to_string exn);
                false
            in
            (* cache correct size so getattr doesn't fall back to manifest HEAD *)
            cache_put key (file_stat (Int64.to_int size) (Unix.gettimeofday ()));
            clear_dirty key;
            if uploaded then begin
              fire_journal ctx ~entry_key:ek ops;
              if !auto_evict then queue_eviction key
            end else Journal.delete_local_pending ~entry_key:ek
          end));
    unlink =
      (fun path ->
        guard "unlink" path (fun () ->
          let key = fuse_to_key ctx path in
          let ek = Journal.entry_key () in
          let ops = [ `Delete (rel_key ctx key) ] in
          Journal.write_local_pending ~entry_key:ek ops;
          Cache.evict ~domain_name:ctx.domain_name
            ~domain_prefix:ctx.domain_prefix key;
          cache_invalidate key;
          S3_store.delete_file ctx.store ~key;
          fire_journal ctx ~entry_key:ek ops));
    mkdir =
      (fun path _mode ->
        guard "mkdir" path (fun () ->
          let key = fuse_to_dir_prefix ctx path in
          let ek = Journal.entry_key () in
          let ops = [ `Mkdir (rel_key ctx key) ] in
          Journal.write_local_pending ~entry_key:ek ops;
          S3_store.create_directory ctx.store ~key;
          fire_journal ctx ~entry_key:ek ops));
    rmdir =
      (fun path ->
        guard "rmdir" path (fun () ->
          let prefix = fuse_to_dir_prefix ctx path in
          let ek = Journal.entry_key () in
          let ops = [ `Rmdir (rel_key ctx prefix) ] in
          Journal.write_local_pending ~entry_key:ek ops;
          S3_store.delete_dir ctx.store ~prefix;
          fire_journal ctx ~entry_key:ek ops));
    rename =
      (fun src dst ->
        guard "rename" src (fun () ->
          let src_key = fuse_to_key ctx src in
          let dst_key = fuse_to_key ctx dst in
          cache_invalidate src_key;
          cache_invalidate dst_key;
          let src_dir = src_key ^ "/" in
          let ek = Journal.entry_key () in
          match S3_store.head_opt ctx.store ~key:src_dir with
            | Some _ ->
                let ops =
                  [ `Rename (rel_key ctx dst_key, rel_key ctx src_key, None) ]
                in
                Journal.write_local_pending ~entry_key:ek ops;
                S3_store.rename_directory ctx.store ~src_prefix:src_dir
                  ~dst_prefix:(dst_key ^ "/");
                fire_journal ctx ~entry_key:ek ops
            | None ->
                let size =
                  if is_cached ctx src_key then
                    (try
                       Some
                         (Unix.LargeFile.stat (local_path ctx src_key))
                           .Unix.LargeFile.st_size
                     with _ -> None)
                  else None
                in
                let ops =
                  [ `Rename (rel_key ctx dst_key, rel_key ctx src_key, size) ]
                in
                Journal.write_local_pending ~entry_key:ek ops;
                if is_cached ctx src_key then begin
                  let src_lp = local_path ctx src_key in
                  let dst_lp = local_path ctx dst_key in
                  Cache.ensure_parent_dir dst_lp;
                  Unix.rename src_lp dst_lp
                end;
                S3_store.rename_file ctx.store ~src_key ~dst_key;
                fire_journal ctx ~entry_key:ek ops));
    truncate =
      (fun path size ->
        guard "truncate" path (fun () ->
          let key = fuse_to_key ctx path in
          (* Must have local file to truncate *)
          if not (is_cached ctx key) then ensure_cached ctx key;
          let lp = local_path ctx key in
          let fd = Unix.openfile lp [Unix.O_WRONLY] 0o644 in
          Unix.ftruncate fd (Int64.to_int size);
          Unix.close fd;
          cache_invalidate key;
          mark_dirty key));
    statfs =
      (fun _path ->
        Fuse.Unix_util.
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
    utime =
      (fun path atime mtime ->
        let key = fuse_to_key ctx path in
        match cache_get key with
          | None -> ()
          | Some st ->
              cache_put key
                Unix.LargeFile.{ st with st_atime = atime; st_mtime = mtime });
    init = (fun () -> ());
  }

(* ── IPC handler ─────────────────────────────────────────────────────────── *)

let ipc_handler ctx line =
  let cmd, arg = Ipc.split_cmd (String.trim line) in
  let key_of_path path =
    (* Accept both absolute mount paths and FUSE-relative paths *)
    if
      String.length path > String.length ctx.mount_point
      && String.sub path 0 (String.length ctx.mount_point) = ctx.mount_point
    then
      fuse_to_key ctx
        (String.sub path
           (String.length ctx.mount_point)
           (String.length path - String.length ctx.mount_point))
    else fuse_to_key ctx path
  in
  match cmd with
    | "EVICT" ->
        let key = key_of_path arg in
        Cache.evict ~domain_name:ctx.domain_name
          ~domain_prefix:ctx.domain_prefix key;
        cache_invalidate key;
        "OK"
    | "RESTORE" -> (
        let key = key_of_path arg in
        try
          ensure_cached ctx key;
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
              (try close_out (open_out (Ipc.auto_evict_path ()))
               with _ -> ());
              "OK"
          | "off" ->
              auto_evict := false;
              (try Unix.unlink (Ipc.auto_evict_path ())
               with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
              "OK"
          | "status" ->
              if !auto_evict then "on" else "off"
          | _ -> "ERROR expected on|off|status")
    | "WAIT" ->
        let key = key_of_path arg in
        if is_cached ctx key then "OK" else "ERROR not cached"
    | "FULL_RESYNC" ->
        Mutex.lock meta_mutex;
        Hashtbl.clear meta_cache;
        Mutex.unlock meta_mutex;
        walk_cache_dir ctx (fun path -> try Unix.unlink path with _ -> ());
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
          let version_key, evictions = drain_pending () in
          (match version_key with
            | None -> ()
            | Some ek -> (
                try S3_store.bump_version ctx.store ek
                with exn ->
                  Log.err "bump_version: %s" (Printexc.to_string exn)));
          List.iter
            (fun key ->
              Cache.evict ~domain_name:ctx.domain_name
                ~domain_prefix:ctx.domain_prefix key)
            evictions
        done)
      ()
  in
  (* ponytail: no self-resync filter; add if spurious eviction from own writes is observed *)
  let _version_poller =
    Thread.create
      (fun () ->
        let known = ref None in
        while true do
          Unix.sleepf 1.0;
          (try
             let version = S3_store.fetch_version ctx.store in
             if !known <> None && version <> !known then begin
               Mutex.lock meta_mutex;
               Hashtbl.clear meta_cache;
               Mutex.unlock meta_mutex;
               walk_cache_dir ctx (fun path ->
                   try Unix.unlink path with _ -> ())
             end;
             known := version
           with _ -> ())
        done)
      ()
  in
  Fuse.Fuse_compat.main ~loop_mode:Fuse.Single_threaded argv
    (make_operations ctx)

(* Resolve a FUSE-relative path from CLI to the key it maps to *)
let path_to_key ctx abs_path =
  if
    String.length abs_path > String.length ctx.mount_point
    && String.sub abs_path 0 (String.length ctx.mount_point) = ctx.mount_point
  then (
    let rel =
      String.sub abs_path
        (String.length ctx.mount_point)
        (String.length abs_path - String.length ctx.mount_point)
    in
    fuse_to_key ctx rel)
  else fuse_to_key ctx abs_path

let key_to_abs_path ctx key = ctx.mount_point ^ key_to_fuse ctx key
