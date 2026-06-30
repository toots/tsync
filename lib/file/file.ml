type store = {
  client : S3_client.t;
  domain_name : string;
  domain_prefix : string;
  chunk_prefix : string;
  trash_prefix : string;
  versioning : bool;
  cache_root : string;
  socket_path : string;
  file_store : File_store.t;
  sync_queue : Sync_queue.t;
  auto_evict : bool ref;
  open_count : (string, int) Hashtbl.t;
  open_count_mutex : Mutex.t;
  pending_evict : (string, unit) Hashtbl.t;
  pending_evict_mutex : Mutex.t;
  dirty_keys : (string, unit) Hashtbl.t;
  dirty_mutex : Mutex.t;
  downloading : (string, unit) Hashtbl.t;
  downloading_mutex : Mutex.t;
  downloading_cond : Condition.t;
}

let make_store ~(conf : Conf.t) ~file_store ~sync_queue ~auto_evict =
  Local.init ~cache_root:conf.cache_root ~domain_name:conf.domain_name;
  {
    client = conf.client;
    domain_name = conf.domain_name;
    domain_prefix = conf.domain_prefix;
    chunk_prefix = conf.chunk_prefix;
    trash_prefix = conf.trash_prefix;
    versioning = conf.versioning;
    cache_root = conf.cache_root;
    socket_path = conf.socket_path;
    file_store;
    sync_queue;
    auto_evict;
    open_count = Hashtbl.create 64;
    open_count_mutex = Mutex.create ();
    pending_evict = Hashtbl.create 16;
    pending_evict_mutex = Mutex.create ();
    dirty_keys = Hashtbl.create 16;
    dirty_mutex = Mutex.create ();
    downloading = Hashtbl.create 8;
    downloading_mutex = Mutex.create ();
    downloading_cond = Condition.create ();
  }

type t = { store : store; key : string }
type buffer = Local_io.buffer

let make ~store ~key = { store; key }

(* ── Path helpers ────────────────────────────────────────────────────────── *)

let rel_key { store; key } =
  let pfx = String.length store.domain_prefix in
  if String.length key > pfx then String.sub key pfx (String.length key - pfx)
  else key

(* ── Local cache ─────────────────────────────────────────────────────────── *)

let is_cached { store; key } =
  Local.is_cached ~cache_root:store.cache_root ~domain_name:store.domain_name
    ~domain_prefix:store.domain_prefix key

let local_path { store; key } =
  Local.cache_path ~cache_root:store.cache_root ~domain_name:store.domain_name
    ~domain_prefix:store.domain_prefix key

let ensure_parent_dir f = Local.ensure_parent_dir (local_path f)

(* ── Manifest ────────────────────────────────────────────────────────────── *)

let read_manifest { store; key } : Manifest.state option =
  match
    Local.read_manifest ~cache_root:store.cache_root ~domain_name:store.domain_name
      ~domain_prefix:store.domain_prefix key
  with
    | None -> None
    | Some s -> ( try Some (Manifest.of_string s) with _ -> None)

let write_manifest { store; key } (state : Manifest.state) =
  let path =
    Local.manifest_path ~cache_root:store.cache_root ~domain_name:store.domain_name
      ~domain_prefix:store.domain_prefix key
  in
  Local.ensure_parent_dir path;
  let tmp = path ^ ".tmp" in
  let oc = open_out tmp in
  output_string oc (Manifest.to_string state);
  close_out oc;
  Unix.rename tmp path

let delete_manifest { store; key } =
  Local.delete_manifest ~cache_root:store.cache_root ~domain_name:store.domain_name
    ~domain_prefix:store.domain_prefix key

(* ── Upload / download ───────────────────────────────────────────────────── *)

let upload ?cancel f =
  let lp = local_path f in
  let mtime = (Unix.stat lp).Unix.st_mtime in
  let state =
    Remote.upload f.store.client ~key:f.key ~src_path:lp ~mtime ?cancel
      ~chunk_prefix:f.store.chunk_prefix ()
  in
  write_manifest f state

let download f =
  let lp = local_path f in
  Local.ensure_parent_dir lp;
  match
    Remote.download f.store.client ~key:f.key ~dst_path:lp
      ~chunk_prefix:f.store.chunk_prefix
  with
    | None -> ()
    | Some state -> write_manifest f state

let ensure_cached f =
  Mutex.lock f.store.downloading_mutex;
  while Hashtbl.mem f.store.downloading f.key do
    Condition.wait f.store.downloading_cond f.store.downloading_mutex
  done;
  if is_cached f then Mutex.unlock f.store.downloading_mutex
  else begin
    Hashtbl.add f.store.downloading f.key ();
    Mutex.unlock f.store.downloading_mutex;
    Fun.protect ~finally:(fun () ->
        Mutex.lock f.store.downloading_mutex;
        Hashtbl.remove f.store.downloading f.key;
        Condition.broadcast f.store.downloading_cond;
        Mutex.unlock f.store.downloading_mutex)
      (fun () -> download f)
  end

(* ── Stat ────────────────────────────────────────────────────────────────── *)

let file_stat size mtime =
  let now = Unix.gettimeofday () in
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
      st_size = size;
      st_atime = now;
      st_mtime = mtime;
      st_ctime = mtime;
    }

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

let manifest_path f =
  Local.manifest_path ~cache_root:f.store.cache_root ~domain_name:f.store.domain_name
    ~domain_prefix:f.store.domain_prefix f.key

let stat f =
  let mp = manifest_path f in
  if not (Sys.file_exists mp) then None
  else if Sys.is_directory mp then Some (dir_stat ())
  else (
    match read_manifest f with
      | Some `Dirty -> (
          match
            try Some (Unix.LargeFile.stat (local_path f)) with _ -> None
          with
            | Some st -> Some st
            | None -> None)
      | Some (`Clean m) -> Some (file_stat m.Manifest.size m.Manifest.mtime)
      | None -> None)

let list_dir f =
  Local.list_dir ~cache_root:f.store.cache_root ~domain_name:f.store.domain_name
    ~domain_prefix:f.store.domain_prefix f.key

(* ── Xattrs ──────────────────────────────────────────────────────────────── *)

let xattrs f =
  match read_manifest f with
    | Some (`Clean m) ->
        [
          ("tsync.h1", m.Manifest.h1);
          ("tsync.h2", m.Manifest.h2);
          ("tsync.size", Int64.to_string m.Manifest.size);
          ("tsync.chunks", string_of_int (List.length m.Manifest.chunks));
        ]
    | _ -> []

(* ── Dirty tracking ──────────────────────────────────────────────────────── *)

let is_dirty f =
  Mutex.lock f.store.dirty_mutex;
  let d = Hashtbl.mem f.store.dirty_keys f.key in
  Mutex.unlock f.store.dirty_mutex;
  d

let set_dirty f =
  Mutex.lock f.store.dirty_mutex;
  Hashtbl.replace f.store.dirty_keys f.key ();
  Mutex.unlock f.store.dirty_mutex

let clear_dirty f =
  Mutex.lock f.store.dirty_mutex;
  Hashtbl.remove f.store.dirty_keys f.key;
  Mutex.unlock f.store.dirty_mutex

let mark_dirty f =
  if not (is_dirty f) then begin
    write_manifest f `Dirty;
    set_dirty f
  end

(* ── Local eviction ──────────────────────────────────────────────────────── *)

let evict { store; key } =
  Local.evict ~cache_root:store.cache_root ~domain_name:store.domain_name ~domain_prefix:store.domain_prefix
    key

let clear_local f =
  evict f;
  delete_manifest f;
  clear_dirty f

let create f =
  ensure_parent_dir f;
  (try close_out (open_out_bin (local_path f))
   with exn ->
     Log.err "File.create %s: %s" f.key (Printexc.to_string exn);
     raise exn);
  write_manifest f `Dirty;
  set_dirty f

let read f (buf : buffer) ~offset =
  if not (is_cached f) then
    Log.debug "read %s: not in local cache, fetching from S3" f.key;
  ensure_cached f;
  Local_io.read (local_path f) buf ~offset

let write f (buf : buffer) ~offset =
  mark_dirty f;
  Local_io.write (local_path f) buf ~offset

let cancel_upload f = Sync_queue.cancel_put f.store.sync_queue f.key

let truncate f size =
  ignore (cancel_upload f);
  ensure_cached f;
  let lp = local_path f in
  let fd = Unix.openfile lp [Unix.O_WRONLY] 0o644 in
  Unix.ftruncate fd (Int64.to_int size);
  Unix.close fd;
  mark_dirty f

let rename_local ~src ~dst =
  if is_cached src then Unix.rename (local_path src) (local_path dst);
  Local.rename_manifest ~cache_root:src.store.cache_root ~domain_name:src.store.domain_name
    ~domain_prefix:src.store.domain_prefix ~src_key:src.key ~dst_key:dst.key

(* ── Synchronous S3 operations ───────────────────────────────────────────── *)

let with_journal f ops s3_op =
  let ek = Journal.entry_key () in
  Journal.write_local_pending ~entry_key:ek ops;
  s3_op ();
  ignore (File_store.write_journal_entry ~entry_key:ek ops f.store.file_store);
  File_store.bump_version f.store.file_store ek;
  Journal.delete_local_pending ~entry_key:ek

let apply_delete f =
  if f.store.versioning then begin
    let trash_key =
      Versioning.trash_key ~s3_key:f.key ~domain_prefix:f.store.domain_prefix
        ~trash_prefix:f.store.trash_prefix
    in
    S3_client.copy f.store.client ~src_key:f.key ~dst_key:trash_key ()
  end;
  S3_client.delete f.store.client ~key:f.key ();
  clear_local f

(* ── Async upload queue ──────────────────────────────────────────────────── *)

let queue_put f =
  let lp = local_path f in
  match try Some (Unix.LargeFile.stat lp) with _ -> None with
    | None -> Log.err "queue_put %s: local file missing, skipping" f.key
    | Some { Unix.LargeFile.st_size = size; _ } ->
        let ek = Journal.entry_key () in
        let ops = [`Put (rel_key f, size)] in
        Journal.write_local_pending ~entry_key:ek ops;
        Sync_queue.post f.store.sync_queue
          (Sync_queue.Put { key = f.key; src_path = lp; entry_key = ek; ops })

(* ── Synchronous S3 operations ───────────────────────────────────────────── *)

let delete f =
  ignore (cancel_upload f);
  with_journal f [`Delete (rel_key f)] (fun () -> apply_delete f)

let mkdir f =
  Local.create_dir ~cache_root:f.store.cache_root ~domain_name:f.store.domain_name
    ~domain_prefix:f.store.domain_prefix f.key;
  with_journal f
    [`Mkdir (rel_key f)]
    (fun () -> File_store.create_directory f.store.file_store ~key:f.key)

let rmdir f =
  Local.delete_dir ~cache_root:f.store.cache_root ~domain_name:f.store.domain_name
    ~domain_prefix:f.store.domain_prefix f.key;
  with_journal f
    [`Rmdir (rel_key f)]
    (fun () -> File_store.delete_dir f.store.file_store ~prefix:f.key)

let rename ~src ~dst =
  let mp = manifest_path src in
  let is_dir = Sys.file_exists mp && Sys.is_directory mp in
  let src =
    if is_dir then make ~store:src.store ~key:(src.key ^ "/") else src
  in
  let dst =
    if is_dir then make ~store:dst.store ~key:(dst.key ^ "/") else dst
  in
  let src_was_uploading = cancel_upload src in
  ignore (cancel_upload dst);
  let size =
    if (not is_dir) && is_cached src then (
      try Some (Unix.LargeFile.stat (local_path src)).Unix.LargeFile.st_size
      with _ -> None)
    else None
  in
  rename_local ~src ~dst;
  if src_was_uploading && is_cached dst then queue_put dst
  else begin
    let rename_op =
      `Rename Journal.{ dst = rel_key dst; src = rel_key src; size; is_dir }
    in
    with_journal dst [rename_op] (fun () ->
        if is_dir then
          File_store.rename_directory dst.store.file_store ~src_prefix:src.key
            ~dst_prefix:dst.key
        else
          File_store.rename_file dst.store.file_store ~src_key:src.key
            ~dst_key:dst.key)
  end

(* ── Open handle tracking and deferred eviction ──────────────────────────── *)

let do_evict f = evict f

let open_file f =
  Mutex.lock f.store.open_count_mutex;
  let n = Option.value ~default:0 (Hashtbl.find_opt f.store.open_count f.key) in
  Hashtbl.replace f.store.open_count f.key (n + 1);
  Mutex.unlock f.store.open_count_mutex

let close_file f =
  Mutex.lock f.store.open_count_mutex;
  let n = Option.value ~default:0 (Hashtbl.find_opt f.store.open_count f.key) in
  let n' = max 0 (n - 1) in
  if n' = 0 then Hashtbl.remove f.store.open_count f.key
  else Hashtbl.replace f.store.open_count f.key n';
  Mutex.unlock f.store.open_count_mutex;
  if n' = 0 then
    if is_dirty f then begin
      clear_dirty f;
      queue_put f
    end
    else begin
      Mutex.lock f.store.pending_evict_mutex;
      let was_pending = Hashtbl.mem f.store.pending_evict f.key in
      Hashtbl.remove f.store.pending_evict f.key;
      Mutex.unlock f.store.pending_evict_mutex;
      if was_pending then do_evict f
    end

let deferred_evict f =
  Mutex.lock f.store.open_count_mutex;
  let count =
    Option.value ~default:0 (Hashtbl.find_opt f.store.open_count f.key)
  in
  Mutex.unlock f.store.open_count_mutex;
  if count = 0 then do_evict f
  else begin
    Mutex.lock f.store.pending_evict_mutex;
    Hashtbl.replace f.store.pending_evict f.key ();
    Mutex.unlock f.store.pending_evict_mutex
  end

let on_upload_done f = if !(f.store.auto_evict) then deferred_evict f
let request_evict f = deferred_evict f
