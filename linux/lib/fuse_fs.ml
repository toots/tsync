type context = {
  store : File_store.t;
  domain_name : string;
  domain_prefix : string;
  mount_point : string;
  sync_queue : Sync_queue.t;
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

(* ── Auto-evict ──────────────────────────────────────────────────────────── *)

let auto_evict = ref (Sys.file_exists (Ipc.auto_evict_path ()))

(* The FUSE kernel creates .fuse_hidden* files to preserve open file
   descriptors when the kernel renames a file that has open FDs (open-while-unlink).
   These are kernel-internal; we must not mirror them to S3. *)
let is_fuse_hidden path =
  let basename = Filename.basename path in
  let prefix = ".fuse_hidden" in
  String.length basename >= String.length prefix
  && String.sub basename 0 (String.length prefix) = prefix

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
  try f () with
    | Unix.Unix_error _ as e -> raise e
    | exn ->
        Log.err "fuse %s %s: unexpected exception: %s" op path
          (Printexc.to_string exn);
        raise (Unix.Unix_error (Unix.EIO, op, path))

(* ── Journal WAL helpers ─────────────────────────────────────────────────── *)

(* Latest journal entry key waiting to be published via version bump.
   The flusher thread drains this every 2 seconds. *)
let pending_version_key : string option ref = ref None
let pending_version_mutex = Mutex.create ()

let set_pending_version ek =
  Mutex.lock pending_version_mutex;
  (* Keep the lexicographically larger key (later timestamp wins) *)
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

(* ── Cache walk (for FULL_RESYNC) ────────────────────────────────────────── *)

let walk_cache_dir ctx f =
  let root = File_store.cache_root ctx.store in
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
                if File_store.is_cached ctx.store key then
                  Unix.LargeFile.stat (File_store.local_path ctx.store key)
                else begin
                  match File_store.read_manifest ctx.store key with
                    | Some (m, mtime) ->
                        let st = file_stat (Int64.to_int m.size) mtime in
                        cache_put key st;
                        st
                    | None -> (
                        (* HEAD on S3 as file, then as directory; stat_file resolves manifest size *)
                          match File_store.stat_file ctx.store ~key with
                          | Some c ->
                              let st = stat_of_entry c in
                              cache_put key st;
                              st
                          | None -> (
                              let dir_key = key ^ "/" in
                              match
                                File_store.head_opt ctx.store ~key:dir_key
                              with
                                | Some _ ->
                                    let st = dir_stat () in
                                    cache_put key st;
                                    st
                                | None ->
                                    raise
                                      (Unix.Unix_error
                                         (Unix.ENOENT, "getattr", path))))
                end
        end);
    readdir =
      (fun path _offset ->
        (* ponytail: always live from S3; add a short-TTL directory listing cache when list latency matters *)
        let prefix = fuse_to_dir_prefix ctx path in
        let files, subdirs = File_store.list_directory ctx.store ~prefix in
        List.iter
          (fun (e : S3_client.file_entry) -> cache_put e.key (stat_of_entry e))
          files;
        List.iter
          (fun subdir_name -> cache_put (prefix ^ subdir_name) (dir_stat ()))
          subdirs;
        let file_names =
          List.map
            (fun (e : S3_client.file_entry) -> Filename.basename e.key)
            files
        in
        ("." :: ".." :: file_names) @ subdirs);
    mknod =
      (fun path _mode ->
        let key = fuse_to_key ctx path in
        let lp = File_store.local_path ctx.store key in
        (try File_store.ensure_parent_dir lp
         with exn ->
           Log.err "mknod ensure_parent_dir %s: %s" lp (Printexc.to_string exn);
           raise (Unix.Unix_error (Unix.EIO, "mknod", path)));
        (try close_out (open_out_bin lp)
         with exn ->
           Log.err "mknod open %s: %s" lp (Printexc.to_string exn);
           raise (Unix.Unix_error (Unix.EIO, "mknod", path)));
        File_store.delete_manifest ctx.store key;
        mark_dirty key);
    fopen =
      (fun path flags ->
        guard "fopen" path (fun () ->
            let key = fuse_to_key ctx path in
            let creating = List.mem Unix.O_CREAT flags in
            let truncating = List.mem Unix.O_TRUNC flags in
            let rdonly = flags = [Unix.O_RDONLY] in
            Log.debug "fopen %s flags=%s cached=%b" path
              (if creating && truncating then "CREAT|TRUNC"
               else if creating then "CREAT"
               else if truncating then "TRUNC"
               else if rdonly then "RDONLY"
               else "OTHER")
              (File_store.is_cached ctx.store key);
            if
              (creating || truncating)
              && not (File_store.is_cached ctx.store key)
            then begin
              (* New or overwrite: create empty local placeholder without downloading *)
              let lp = File_store.local_path ctx.store key in
              File_store.ensure_parent_dir lp;
              close_out (open_out_bin lp);
              File_store.delete_manifest ctx.store key
            end
            else if truncating then begin
              (* Cancel any in-flight upload BEFORE truncating so the worker
               does not read a zero-byte file and upload corrupt data. *)
              ignore (Sync_queue.cancel_put ctx.sync_queue key);
              let lp = File_store.local_path ctx.store key in
              let fd = Unix.openfile lp [Unix.O_WRONLY; Unix.O_TRUNC] 0o644 in
              Unix.close fd;
              File_store.delete_manifest ctx.store key;
              cache_invalidate key;
              mark_dirty key
            end
            else if not (File_store.is_cached ctx.store key) then
              File_store.ensure_cached ctx.store key;
            None));
    read =
      (fun path buf offset _size ->
        guard "read" path (fun () ->
            let key = fuse_to_key ctx path in
            if not (File_store.is_cached ctx.store key) then
              Log.err
                "read %s: not in local cache, downloading from S3 (offset=%Ld)"
                path offset;
            File_store.ensure_cached ctx.store key;
            let lp = File_store.local_path ctx.store key in
            if offset = 0L then
              Log.debug "read %s: offset=0, local_size=%Ld" path
                (try (Unix.LargeFile.stat lp).Unix.LargeFile.st_size
                 with _ -> -1L);
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
            let lp = File_store.local_path ctx.store key in
            File_store.ensure_parent_dir lp;
            let size = Bigarray.Array1.dim buf in
            let tmp = Bytes.create size in
            for i = 0 to size - 1 do
              Bytes.set tmp i buf.{i}
            done;
            Log.debug "write %s: offset=%Ld size=%d" path offset size;
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
            if writing && not (is_fuse_hidden path) then begin
              Log.debug "release %s: queued for upload" path;
              let lp = File_store.local_path ctx.store key in
              let ek = Journal.entry_key () in
              match try Some (Unix.LargeFile.stat lp) with _ -> None with
                | None ->
                    Log.err "release %s: local file missing, skipping upload"
                      path;
                    clear_dirty key
                | Some { Unix.LargeFile.st_size = size; _ } ->
                    Log.debug "release %s: size=%Ld" path size;
                    if Int64.compare size 1_000_000L > 0 then
                      Log.debug "release %s: local_md5=%s" path
                        (Digest.to_hex (Digest.file lp));
                    let ops = [`Put (rel_key ctx key, size)] in
                    Journal.write_local_pending ~entry_key:ek ops;
                    cache_put key
                      (file_stat (Int64.to_int size) (Unix.gettimeofday ()));
                    clear_dirty key;
                    Sync_queue.post ctx.sync_queue
                      (Sync_queue.Put
                         { key; src_path = lp; entry_key = ek; ops })
            end));
    unlink =
      (fun path ->
        guard "unlink" path (fun () ->
            let key = fuse_to_key ctx path in
            cache_invalidate key;
            if is_fuse_hidden path then begin
              (* FUSE kernel internal file: just evict locally, no S3 operation *)
              File_store.evict ctx.store key;
              File_store.delete_manifest ctx.store key
            end
            else begin
              let ek = Journal.entry_key () in
              let ops = [`Delete (rel_key ctx key)] in
              (* post runs cancel_put before S3 delete; evict only after so that
               the upload sees cancel=true before its local file disappears *)
              Sync_queue.post ctx.sync_queue
                (Sync_queue.Delete { key; entry_key = ek; ops });
              File_store.evict ctx.store key;
              File_store.delete_manifest ctx.store key
            end));
    mkdir =
      (fun path _mode ->
        guard "mkdir" path (fun () ->
            let key = fuse_to_dir_prefix ctx path in
            cache_put (fuse_to_key ctx path) (dir_stat ());
            let ek = Journal.entry_key () in
            let ops = [`Mkdir (rel_key ctx key)] in
            Sync_queue.post ctx.sync_queue
              (Sync_queue.Mkdir { key; entry_key = ek; ops })));
    rmdir =
      (fun path ->
        guard "rmdir" path (fun () ->
            let prefix = fuse_to_dir_prefix ctx path in
            let ek = Journal.entry_key () in
            let ops = [`Rmdir (rel_key ctx prefix)] in
            Sync_queue.post ctx.sync_queue
              (Sync_queue.Rmdir { key = prefix; entry_key = ek; ops })));
    rename =
      (fun src dst ->
        guard "rename" src (fun () ->
            let src_key = fuse_to_key ctx src in
            let dst_key = fuse_to_key ctx dst in
            let src_is_dir =
              match cache_get src_key with
                | Some { Unix.LargeFile.st_kind = Unix.S_DIR; _ } -> true
                | _ -> false
            in
            cache_invalidate src_key;
            cache_invalidate dst_key;
            if is_fuse_hidden dst then begin
              (* FUSE kernel internal: rename to preserve open FDs during unlink.
               Leave any in-flight Put for src running; just move the local file. *)
              if File_store.is_cached ctx.store src_key then begin
                let src_lp = File_store.local_path ctx.store src_key in
                let dst_lp = File_store.local_path ctx.store dst_key in
                File_store.ensure_parent_dir dst_lp;
                Unix.rename src_lp dst_lp
              end;
              File_store.rename_manifest ctx.store ~src_key ~dst_key
            end
            else (
              let ek = Journal.entry_key () in
              if src_is_dir then begin
                let ops =
                  [
                    `Rename
                      Journal.
                        {
                          dst = rel_key ctx (dst_key ^ "/");
                          src = rel_key ctx (src_key ^ "/");
                          size = None;
                          is_dir = true;
                        };
                  ]
                in
                Sync_queue.post ctx.sync_queue
                  (Sync_queue.Rename
                     {
                       src_key = src_key ^ "/";
                       dst_key = dst_key ^ "/";
                       src_is_dir = true;
                       dst_local_path = "";
                       entry_key = ek;
                       put_ops = ops;
                       rename_ops = ops;
                     })
              end
              else begin
                let dst_lp = File_store.local_path ctx.store dst_key in
                let size =
                  if File_store.is_cached ctx.store src_key then (
                    try
                      Some
                        (Unix.LargeFile.stat
                           (File_store.local_path ctx.store src_key))
                          .Unix.LargeFile.st_size
                    with _ -> None)
                  else None
                in
                if File_store.is_cached ctx.store src_key then begin
                  let src_lp = File_store.local_path ctx.store src_key in
                  File_store.ensure_parent_dir dst_lp;
                  Unix.rename src_lp dst_lp
                end;
                File_store.rename_manifest ctx.store ~src_key ~dst_key;
                Sync_queue.post ctx.sync_queue
                  (Sync_queue.Rename
                     {
                       src_key;
                       dst_key;
                       src_is_dir = false;
                       dst_local_path = dst_lp;
                       entry_key = ek;
                       put_ops =
                         [
                           `Put
                             (rel_key ctx dst_key, Option.value ~default:0L size);
                         ];
                       rename_ops =
                         [
                           `Rename
                             Journal.
                               {
                                 dst = rel_key ctx dst_key;
                                 src = rel_key ctx src_key;
                                 size;
                                 is_dir = false;
                               };
                         ];
                     })
              end)));
    truncate =
      (fun path size ->
        guard "truncate" path (fun () ->
            let key = fuse_to_key ctx path in
            Log.debug "truncate %s size=%Ld" path size;
            if not (is_fuse_hidden path) then
              ignore (Sync_queue.cancel_put ctx.sync_queue key);
            (* Must have local file to truncate *)
            if not (File_store.is_cached ctx.store key) then
              File_store.ensure_cached ctx.store key;
            let lp = File_store.local_path ctx.store key in
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
        guard "utime" path (fun () ->
            let key = fuse_to_key ctx path in
            match cache_get key with
              | None -> ()
              | Some st ->
                  cache_put key
                    Unix.LargeFile.
                      { st with st_atime = atime; st_mtime = mtime }));
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
        Sync_queue.post ctx.sync_queue
          (Sync_queue.Evict { key = key_of_path arg });
        "OK"
    | "RESTORE" -> (
        let key = key_of_path arg in
        try
          File_store.ensure_cached ctx.store key;
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
    | "WAIT" ->
        let key = key_of_path arg in
        if File_store.is_cached ctx.store key then "OK" else "ERROR not cached"
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
          match drain_pending_version () with
            | None -> ()
            | Some ek -> (
                try File_store.bump_version ctx.store ek
                with exn ->
                  Log.err "bump_version: %s" (Printexc.to_string exn))
        done)
      ()
  in
  let _version_poller =
    Thread.create
      (fun () ->
        let my_uuid = Journal.client_uuid () in
        let known = ref None in
        while true do
          Unix.sleepf 1.0;
          try
            let version = File_store.fetch_version ctx.store in
            (match (!known, version) with
              | Some k, Some v when v <> k -> (
                  let all_entries =
                    File_store.list_journal_keys ~start_after:k ctx.store ()
                  in
                  let foreign =
                    List.filter (fun (_, uuid) -> uuid <> my_uuid) all_entries
                  in
                  match foreign with
                    | [] when all_entries = [] ->
                        (* Truly no entries since k: journal may be pruned.
                            Full wipe as a conservative fallback. *)
                        Mutex.lock meta_mutex;
                        Hashtbl.clear meta_cache;
                        Mutex.unlock meta_mutex;
                        walk_cache_dir ctx (fun path ->
                            try Unix.unlink path with _ -> ())
                    | [] ->
                        (* All entries since k are our own: nothing to do. *)
                        ()
                    | _ ->
                        let changed_keys =
                          List.concat_map
                            (fun (ek, _) ->
                              match
                                File_store.get_journal_entry ctx.store ek
                              with
                                | None -> []
                                | Some ops ->
                                    List.concat_map
                                      (fun op ->
                                        match op with
                                          | `Put (k, _)
                                          | `Delete k
                                          | `Mkdir k
                                          | `Rmdir k ->
                                              [ctx.domain_prefix ^ k]
                                          | `Rename { Journal.dst; src; _ } ->
                                              [
                                                ctx.domain_prefix ^ dst;
                                                ctx.domain_prefix ^ src;
                                              ])
                                      ops)
                            foreign
                        in
                        List.iter
                          (fun key ->
                            Sync_queue.post ctx.sync_queue
                              (Sync_queue.Evict { key }))
                          changed_keys)
              | _ -> ());
            known := version
          with _ -> ()
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
