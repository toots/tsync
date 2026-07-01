type buffer = Local_io.buffer

module type S = sig
  type t = string

  val is_cached : t -> bool
  val local_path : t -> string
  val manifest_path : t -> string
  val ensure_parent_dir : t -> unit
  val rel_key : t -> string
  val read_manifest : t -> Manifest.state option
  val write_manifest : t -> Manifest.state -> unit
  val delete_manifest : t -> unit
  val upload : ?cancel:bool Atomic.t -> t -> unit
  val download : t -> unit
  val ensure_cached : t -> unit
  val stat : t -> Unix.LargeFile.stats option
  val list_dir : t -> string list
  val xattrs : t -> (string * string) list
  val is_dirty : t -> bool
  val set_dirty : t -> unit
  val clear_dirty : t -> unit
  val mark_dirty : t -> unit
  val evict : t -> unit
  val clear_local : t -> unit
  val create : t -> unit
  val read : t -> buffer -> offset:int64 -> int
  val write : t -> buffer -> offset:int64 -> int
  val cancel_upload : t -> bool
  val truncate : t -> int64 -> unit
  val rename_local : src:t -> dst:t -> unit
  val apply_delete : t -> unit
  val queue_put : t -> unit
  val delete : t -> unit
  val mkdir : t -> unit
  val rmdir : t -> unit
  val rename : src:t -> dst:t -> unit
  val open_file : t -> unit
  val close_file : t -> unit
  val deferred_evict : t -> unit
  val on_upload_done : t -> unit
  val request_evict : t -> unit
  val auto_evict : bool ref
end

module Make (C : Conf.S) (Sq : Sync_queue.S) : S = struct
  module J = Journal.Make (C)
  module Fs = File_store.Make (C)
  module R = Remote.Make (C)

  type t = string

  let auto_evict : bool ref = ref false
  let open_count : (string, int) Hashtbl.t = Hashtbl.create 64
  let open_count_mutex = Mutex.create ()
  let pending_evict : (string, unit) Hashtbl.t = Hashtbl.create 16
  let pending_evict_mutex = Mutex.create ()
  let dirty_keys : (string, unit) Hashtbl.t = Hashtbl.create 16
  let dirty_mutex = Mutex.create ()
  let downloading : (string, unit) Hashtbl.t = Hashtbl.create 8
  let downloading_mutex = Mutex.create ()
  let downloading_cond = Condition.create ()
  let () = Local.init ~cache_root:C.cache_root ~domain_name:C.domain_name

  (* ── Path helpers ──────────────────────────────────────────────────────── *)

  let rel_key key =
    let pfx = String.length C.domain_prefix in
    if String.length key > pfx then String.sub key pfx (String.length key - pfx)
    else key

  let is_cached key =
    Local.is_cached ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix key

  let local_path key =
    Local.cache_path ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix key

  let ensure_parent_dir key = Local.ensure_parent_dir (local_path key)

  let manifest_path key =
    Local.manifest_path ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix key

  (* ── Manifest ──────────────────────────────────────────────────────────── *)

  let read_manifest key : Manifest.state option =
    match
      Local.read_manifest ~cache_root:C.cache_root ~domain_name:C.domain_name
        ~domain_prefix:C.domain_prefix key
    with
      | None -> None
      | Some s -> ( try Some (Manifest.of_string s) with _ -> None)

  let write_manifest key (state : Manifest.state) =
    let path = manifest_path key in
    Local.ensure_parent_dir path;
    let tmp = path ^ ".tmp" in
    let oc = open_out tmp in
    output_string oc (Manifest.to_string state);
    close_out oc;
    Unix.rename tmp path

  let delete_manifest key =
    Local.delete_manifest ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix key

  (* ── Upload / download ─────────────────────────────────────────────────── *)

  let upload ?cancel key =
    let lp = local_path key in
    let mtime = (Unix.stat lp).Unix.st_mtime in
    let state = R.upload ~key ~src_path:lp ~mtime ?cancel () in
    write_manifest key state

  let download key =
    let lp = local_path key in
    Local.ensure_parent_dir lp;
    match R.download ~key ~dst_path:lp with
      | None -> ()
      | Some state -> write_manifest key state

  let ensure_cached key =
    Mutex.lock downloading_mutex;
    while Hashtbl.mem downloading key do
      Condition.wait downloading_cond downloading_mutex
    done;
    if is_cached key then Mutex.unlock downloading_mutex
    else begin
      Hashtbl.add downloading key ();
      Mutex.unlock downloading_mutex;
      Fun.protect
        ~finally:(fun () ->
          Mutex.lock downloading_mutex;
          Hashtbl.remove downloading key;
          Condition.broadcast downloading_cond;
          Mutex.unlock downloading_mutex)
        (fun () -> download key)
    end

  (* ── Stat ──────────────────────────────────────────────────────────────── *)

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

  let stat key =
    let mp = manifest_path key in
    if not (Sys.file_exists mp) then None
    else if Sys.is_directory mp then Some (dir_stat ())
    else (
      match read_manifest key with
        | Some `Dirty -> (
            match
              try Some (Unix.LargeFile.stat (local_path key)) with _ -> None
            with
              | Some st -> Some st
              | None -> None)
        | Some (`Clean m) -> Some (file_stat m.Manifest.size m.Manifest.mtime)
        | None -> None)

  let list_dir key =
    Local.list_dir ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix key

  (* ── Xattrs ────────────────────────────────────────────────────────────── *)

  let xattrs key =
    match read_manifest key with
      | Some (`Clean m) ->
          [
            ("tsync.h1", m.Manifest.h1);
            ("tsync.h2", m.Manifest.h2);
            ("tsync.size", Int64.to_string m.Manifest.size);
            ("tsync.chunks", string_of_int (List.length m.Manifest.chunks));
          ]
      | _ -> []

  (* ── Dirty tracking ────────────────────────────────────────────────────── *)

  let is_dirty key =
    Mutex.lock dirty_mutex;
    let d = Hashtbl.mem dirty_keys key in
    Mutex.unlock dirty_mutex;
    d

  let set_dirty key =
    Mutex.lock dirty_mutex;
    Hashtbl.replace dirty_keys key ();
    Mutex.unlock dirty_mutex

  let clear_dirty key =
    Mutex.lock dirty_mutex;
    Hashtbl.remove dirty_keys key;
    Mutex.unlock dirty_mutex

  let mark_dirty key =
    if not (is_dirty key) then begin
      write_manifest key `Dirty;
      set_dirty key
    end

  (* ── Local eviction ────────────────────────────────────────────────────── *)

  let evict key =
    Local.evict ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix key

  let clear_local key =
    evict key;
    delete_manifest key;
    clear_dirty key

  let create key =
    ensure_parent_dir key;
    (try close_out (open_out_bin (local_path key))
     with exn ->
       Log.err "File.create %s: %s" key (Printexc.to_string exn);
       raise exn);
    write_manifest key `Dirty;
    set_dirty key

  let read key (buf : buffer) ~offset =
    if not (is_cached key) then
      Log.debug "read %s: not in local cache, fetching from backend" key;
    ensure_cached key;
    Local_io.read (local_path key) buf ~offset

  let write key (buf : buffer) ~offset =
    mark_dirty key;
    Local_io.write (local_path key) buf ~offset

  let cancel_upload key = Sq.cancel_put key

  let truncate key size =
    ignore (cancel_upload key);
    ensure_cached key;
    let lp = local_path key in
    let fd = Unix.openfile lp [Unix.O_WRONLY] 0o644 in
    Unix.ftruncate fd (Int64.to_int size);
    Unix.close fd;
    mark_dirty key

  let rename_local ~src ~dst =
    if is_cached src then Unix.rename (local_path src) (local_path dst);
    Local.rename_manifest ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix ~src_key:src ~dst_key:dst

  (* ── Synchronous backend operations ────────────────────────────────────── *)

  let with_journal key ops s3_op =
    let ek = J.entry_key () in
    J.write_local_pending ~entry_key:ek ops;
    s3_op ();
    ignore (Fs.write_journal_entry ~entry_key:ek ops);
    Fs.bump_version ek;
    J.delete_local_pending ~entry_key:ek

  let apply_delete key =
    if C.versioning then begin
      let trash_key =
        Versioning.trash_key ~s3_key:key ~domain_prefix:C.domain_prefix
          ~trash_prefix:C.trash_prefix
      in
      List.iter
        (fun (module B : Backend.S) ->
          B.copy ~src_key:key ~dst_key:trash_key ())
        C.backends
    end;
    List.iter (fun (module B : Backend.S) -> B.delete ~key ()) C.backends;
    clear_local key

  (* ── Async upload queue ────────────────────────────────────────────────── *)

  let queue_put key =
    let lp = local_path key in
    match try Some (Unix.LargeFile.stat lp) with _ -> None with
      | None -> Log.err "queue_put %s: local file missing, skipping" key
      | Some { Unix.LargeFile.st_size = size; _ } ->
          let ek = J.entry_key () in
          let ops = [`Put (rel_key key, size)] in
          J.write_local_pending ~entry_key:ek ops;
          Sq.post ~key ~src_path:lp ~entry_key:ek ~ops

  let delete key =
    ignore (cancel_upload key);
    with_journal key [`Delete (rel_key key)] (fun () -> apply_delete key)

  let mkdir key =
    Local.create_dir ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix key;
    with_journal key [`Mkdir (rel_key key)] (fun () -> Fs.create_directory ~key)

  let rmdir key =
    Local.delete_dir ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix key;
    with_journal key
      [`Rmdir (rel_key key)]
      (fun () -> Fs.delete_dir ~prefix:key)

  let rename ~src ~dst =
    let mp = manifest_path src in
    let is_dir = Sys.file_exists mp && Sys.is_directory mp in
    let src = if is_dir then src ^ "/" else src in
    let dst = if is_dir then dst ^ "/" else dst in
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
          if is_dir then Fs.rename_directory ~src_prefix:src ~dst_prefix:dst
          else Fs.rename_file ~src_key:src ~dst_key:dst)
    end

  (* ── Open handle tracking and deferred eviction ────────────────────────── *)

  let do_evict key = evict key

  let open_file key =
    Mutex.lock open_count_mutex;
    let n = Option.value ~default:0 (Hashtbl.find_opt open_count key) in
    Hashtbl.replace open_count key (n + 1);
    Mutex.unlock open_count_mutex

  let close_file key =
    Mutex.lock open_count_mutex;
    let n = Option.value ~default:0 (Hashtbl.find_opt open_count key) in
    let n' = max 0 (n - 1) in
    if n' = 0 then Hashtbl.remove open_count key
    else Hashtbl.replace open_count key n';
    Mutex.unlock open_count_mutex;
    if n' = 0 then
      if is_dirty key then begin
        clear_dirty key;
        queue_put key
      end
      else begin
        Mutex.lock pending_evict_mutex;
        let was_pending = Hashtbl.mem pending_evict key in
        Hashtbl.remove pending_evict key;
        Mutex.unlock pending_evict_mutex;
        if was_pending then do_evict key
      end

  let deferred_evict key =
    Mutex.lock open_count_mutex;
    let count = Option.value ~default:0 (Hashtbl.find_opt open_count key) in
    Mutex.unlock open_count_mutex;
    if count = 0 then do_evict key
    else begin
      Mutex.lock pending_evict_mutex;
      Hashtbl.replace pending_evict key ();
      Mutex.unlock pending_evict_mutex
    end

  let on_upload_done key = if !auto_evict then deferred_evict key
  let request_evict key = deferred_evict key
end
