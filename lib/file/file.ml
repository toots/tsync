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
  val mark_open : t -> unit
  val mark_closed : t -> int
  val is_open : t -> bool
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

  (** Restore a saved version of [key] to the live location. With [version] the
      given timestamp is restored, otherwise the most recent one. Only the small
      manifest is copied back; content stays evicted (dataless) and is fetched
      lazily on next open. *)
  val revert : ?version:string -> t -> unit

  val apply_foreign_ops : Journal.op list -> unit
end

module Make (C : Conf.S) (Sq : Sync_queue.S) : S = struct
  module J = Journal.Make (C)
  module Fs = File_store.Make (C)
  module R = Remote.Make (C)

  type t = string

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

  (* ── Upload / download ─────────────────────────────────────────────────── *)

  let upload ?cancel key =
    let lp = local_path key in
    let mtime = (Unix.stat lp).Unix.st_mtime in
    let state = R.upload ~key ~src_path:lp ~mtime ?cancel () in
    write_manifest key state;
    clear_dirty key

  let download key =
    let lp = local_path key in
    Local.ensure_parent_dir lp;
    match read_manifest key with
      | Some (`Clean manifest) -> R.download_chunks ~dst_path:lp manifest
      | _ -> (
          match R.download ~key ~dst_path:lp with
            | None -> ()
            | Some state -> write_manifest key state)

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

  let mark_dirty key =
    if not (is_dirty key) then begin
      write_manifest key `Dirty;
      set_dirty key
    end

  (* ── Open-handle tracking ──────────────────────────────────────────────── *)

  let open_count : (string, int) Hashtbl.t = Hashtbl.create 64
  let open_count_mutex = Mutex.create ()

  let mark_open key =
    Mutex.lock open_count_mutex;
    let n = Option.value ~default:0 (Hashtbl.find_opt open_count key) in
    Hashtbl.replace open_count key (n + 1);
    Mutex.unlock open_count_mutex

  let mark_closed key =
    Mutex.lock open_count_mutex;
    let n = Option.value ~default:0 (Hashtbl.find_opt open_count key) in
    let n' = max 0 (n - 1) in
    if n' = 0 then Hashtbl.remove open_count key
    else Hashtbl.replace open_count key n';
    Mutex.unlock open_count_mutex;
    n'

  let is_open key =
    Mutex.lock open_count_mutex;
    let n = Option.value ~default:0 (Hashtbl.find_opt open_count key) in
    Mutex.unlock open_count_mutex;
    n > 0

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
    (* The pending entry is for crash recovery. A synchronous failure is
       reported to the caller instead; keeping the entry would make
       recover_pending_ops replay a known-failed op at every startup. *)
    (try s3_op ()
     with exn ->
       J.delete_local_pending ~entry_key:ek;
       raise exn);
    ignore (Fs.write_journal_entry ~entry_key:ek ops);
    Fs.bump_cursor ek;
    J.delete_local_pending ~entry_key:ek

  let save_version key =
    if C.versioning then
      Versioning.save ~backends:C.backends ~domain_prefix:C.domain_prefix
        ~versions_prefix:C.versions_prefix ~key

  let apply_delete key =
    save_version key;
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

  (* Publish an already-chunked file under [key]: its chunks are on the
     backend, only the manifest key and a journal entry are missing. *)
  let publish_manifest key (state : Manifest.state) =
    match state with
      | `Dirty -> ()
      | `Clean m ->
          List.iter
            (fun (module B : Backend.S) ->
              B.put ~key ~data:(Manifest.to_string state) ())
            C.backends;
          let ek =
            Fs.write_journal_entry [`Put (rel_key key, m.Manifest.size)]
          in
          Fs.bump_cursor ek

  let conflict_name rel =
    let base = Filename.basename rel in
    let dir = Filename.dirname rel in
    let name, ext =
      match String.rindex_opt base '.' with
        | None -> (base, "")
        | Some i ->
            (String.sub base 0 i, String.sub base i (String.length base - i))
    in
    let base =
      Printf.sprintf "%s (conflicted copy from %s)%s" name C.client_name ext
    in
    if dir = "." then base else dir ^ "/" ^ base

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
      if not is_dir then save_version src;
      let rename_op =
        `Rename Journal.{ dst = rel_key dst; src = rel_key src; size; is_dir }
      in
      try
        with_journal dst [rename_op] (fun () ->
            if is_dir then Fs.rename_directory ~src_prefix:src ~dst_prefix:dst
            else Fs.rename_file ~src_key:src ~dst_key:dst)
      with exn when (not is_dir) && Option.is_none (Fs.head_opt ~key:src) -> (
        (* src is gone from the backend: another client renamed or deleted it
           concurrently. The file already moved locally; publish it as a new,
           conflict-marked file instead, its chunks are still on the backend. *)
        let conflict = C.domain_prefix ^ conflict_name (rel_key dst) in
        match read_manifest dst with
          | Some (`Clean _ as state) ->
              rename_local ~src:dst ~dst:conflict;
              publish_manifest conflict state
          | Some `Dirty when is_cached dst ->
              rename_local ~src:dst ~dst:conflict;
              queue_put conflict
          | _ -> raise exn)
    end

  (* ── Versioning restore ────────────────────────────────────────────────── *)

  let latest_version primary dir =
    let (module B : Backend.S) = primary in
    List.fold_left
      (fun acc (e : Backend.file_entry) ->
        match Versioning.parse ~versions_prefix:C.versions_prefix e.key with
          | None -> acc
          | Some (_, ts) -> (
              let n = Int64.of_string ts in
              match acc with
                | Some (_, best) when Int64.compare best n >= 0 -> acc
                | _ -> Some (e.key, n)))
      None
      (B.list_all ~prefix:dir ())

  let revert ?version key =
    let (module B : Backend.S) =
      match C.backends with b :: _ -> b | [] -> failwith "no backends configured"
    in
    let dir =
      Versioning.version_dir ~s3_key:key ~domain_prefix:C.domain_prefix
        ~versions_prefix:C.versions_prefix
    in
    let src_key =
      match version with
        | Some ts -> dir ^ ts
        | None -> (
            match latest_version (module B) dir with
              | Some (k, _) -> k
              | None -> failwith ("no versions for " ^ rel_key key))
    in
    let data = B.get ~key:src_key () in
    match Manifest.of_string data with
      | `Dirty -> failwith "cannot restore a dirty version"
      | `Clean m ->
          ignore (cancel_upload key);
          List.iter
            (fun (module B : Backend.S) -> B.put ~key ~data ())
            C.backends;
          write_manifest key (`Clean m);
          (* Dataless: keep the manifest sidecar, drop any cached content so the
             restored bytes are fetched lazily on next open. *)
          evict key;
          clear_dirty key;
          let ek = Fs.write_journal_entry [`Put (rel_key key, m.Manifest.size)] in
          Fs.bump_cursor ek

  (* ── Foreign op application (sync) ────────────────────────────────────── *)

  let apply_foreign_ops ops =
    List.iter
      (fun op ->
        try
          match op with
            | `Put (rel, _) ->
                let key = C.domain_prefix ^ rel in
                if (not (is_dirty key)) && not (is_open key) then (
                  ignore (cancel_upload key);
                  match R.fetch_manifest ~key () with
                    | None -> ()
                    | Some state ->
                        write_manifest key state;
                        evict key)
            | `Delete rel ->
                let key = C.domain_prefix ^ rel in
                if (not (is_dirty key)) && not (is_open key) then (
                  ignore (cancel_upload key);
                  clear_local key)
            | `Mkdir rel ->
                Local.create_dir ~cache_root:C.cache_root
                  ~domain_name:C.domain_name ~domain_prefix:C.domain_prefix
                  (C.domain_prefix ^ rel)
            | `Rmdir rel ->
                Local.delete_dir ~cache_root:C.cache_root
                  ~domain_name:C.domain_name ~domain_prefix:C.domain_prefix
                  (C.domain_prefix ^ rel)
            | `Rename { Journal.src; dst; is_dir = true; _ } ->
                let src_key = C.domain_prefix ^ src in
                let dst_key = C.domain_prefix ^ dst in
                if
                  Sys.file_exists (manifest_path src_key)
                  && (not (is_dirty src_key))
                  && not (is_open src_key)
                then rename_local ~src:src_key ~dst:dst_key
            | `Rename { Journal.src; dst; is_dir = false; _ } ->
                let src_key = C.domain_prefix ^ src in
                let dst_key = C.domain_prefix ^ dst in
                if
                  Sys.file_exists (manifest_path src_key)
                  && (not (is_dirty src_key))
                  && not (is_open src_key)
                then rename_local ~src:src_key ~dst:dst_key
                else if (not (is_dirty dst_key)) && not (is_open dst_key) then (
                  (* No local copy of src (e.g. we renamed it ourselves and
                     published the result): adopt the remote state of dst. *)
                    match R.fetch_manifest ~key:dst_key () with
                    | Some (`Clean _ as state) -> write_manifest dst_key state
                    | _ -> ())
        with exn -> Log.err "apply_foreign_ops: %s" (Printexc.to_string exn))
      ops
end
