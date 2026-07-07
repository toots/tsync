open Lwt.Syntax

type buffer = Local_io.buffer

module type S = sig
  type t = string

  val is_cached : t -> bool Lwt.t
  val local_path : t -> string
  val manifest_path : t -> string
  val ensure_parent_dir : t -> unit Lwt.t
  val rel_key : t -> string
  val read_manifest : t -> Manifest.state option Lwt.t
  val resolved_manifest : t -> Manifest.state option Lwt.t
  val write_manifest : t -> Manifest.state -> unit Lwt.t
  val delete_manifest : t -> unit Lwt.t
  val upload : ?cancel:bool ref -> t -> unit Lwt.t
  val download : t -> unit Lwt.t
  val ensure_cached : t -> unit Lwt.t
  val stat : t -> Unix.LargeFile.stats option Lwt.t
  val list_dir : t -> string list Lwt.t
  val xattrs : t -> (string * string) list Lwt.t
  val is_dirty : t -> bool
  val set_dirty : t -> unit
  val clear_dirty : t -> unit
  val mark_dirty : t -> unit Lwt.t
  val mark_open : t -> unit
  val mark_closed : t -> int
  val is_open : t -> bool
  val downloading_count : unit -> int
  val dirty_count : unit -> int
  val open_files_count : unit -> int
  val downloads_completed_count : unit -> int
  val evict : t -> unit Lwt.t
  val clear_local : t -> unit Lwt.t
  val create : t -> unit Lwt.t
  val read : t -> buffer -> offset:int64 -> int Lwt.t
  val write : t -> buffer -> offset:int64 -> int Lwt.t
  val cancel_upload : t -> bool
  val truncate : t -> int64 -> unit Lwt.t
  val rename_local : src:t -> dst:t -> unit Lwt.t
  val apply_delete : t -> unit Lwt.t
  val queue_put : t -> unit Lwt.t
  val delete : t -> unit Lwt.t
  val mkdir : t -> unit Lwt.t
  val rmdir : t -> unit Lwt.t
  val rename : src:t -> dst:t -> unit Lwt.t

  (** Restore a saved version of [key] to the live location. With [version] the
      given timestamp is restored, otherwise the most recent one. Only the small
      manifest is copied back; content stays evicted (dataless) and is fetched
      lazily on next open. *)
  val revert : ?version:string -> t -> unit Lwt.t

  val apply_foreign_ops : Journal.op list -> unit Lwt.t
end

module Make (C : Conf.S) (Sq : Sync_queue.S) : S = struct
  module J = Journal.Make (C)
  module Fs = File_store.Make (C)
  module R = Remote.Make (C)

  type t = string

  (* All File operations run on the single Lwt event-loop thread, so plain
     hashtables need no locking. Metadata mutations (delete/mkdir/rmdir/rename/
     revert and foreign-op application) are serialized through [meta_mutex] to
     preserve the ordering the old single-threaded FUSE loop provided; reads,
     downloads and uploads stay concurrent.
     ponytail: one global metadata lock; switch to per-key locks only if
     unrelated metadata ops measurably contend. *)
  let meta_mutex = Lwt_mutex.create ()
  let with_meta f = Lwt_mutex.with_lock meta_mutex f
  let dirty_keys : (string, unit) Hashtbl.t = Hashtbl.create 16
  let downloading : (string, unit Lwt.t) Hashtbl.t = Hashtbl.create 8

  (* Bounds concurrent file downloads. The per-key [downloading] table dedups
     the same key; this pool caps how many distinct downloads run at once. *)
  let download_pool =
    Lwt_pool.create (max 1 C.max_downloads) (fun () -> Lwt.return_unit)

  let downloads_completed = ref 0

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

  let stat_opt path =
    Lwt.catch
      (fun () ->
        let+ st = Lwt_unix.LargeFile.stat path in
        Some st)
      (fun _ -> Lwt.return_none)

  (* ── Manifest ──────────────────────────────────────────────────────────── *)

  let read_manifest key : Manifest.state option Lwt.t =
    let* raw =
      Local.read_manifest ~cache_root:C.cache_root ~domain_name:C.domain_name
        ~domain_prefix:C.domain_prefix key
    in
    match raw with
      | None -> Lwt.return_none
      | Some s -> (
          try Lwt.return_some (Manifest.of_string s) with _ -> Lwt.return_none)

  (* Prefer the local sidecar (cheap, and the only place a Dirty in-progress state
     lives); for a backend-only file with no sidecar, fetch and parse the manifest so
     callers get the real logical size/mtime rather than the manifest object's own
     byte size. ponytail: one HEAD+GET per uncached file; add a metadata cache if a
     cold full-directory enumeration gets slow. *)
  let resolved_manifest key : Manifest.state option Lwt.t =
    let* m = read_manifest key in
    match m with Some _ -> Lwt.return m | None -> R.fetch_manifest ~key ()

  let write_manifest key (state : Manifest.state) =
    let path = manifest_path key in
    let* () = Local.ensure_parent_dir path in
    let tmp = path ^ ".tmp" in
    let* () =
      Lwt_io.with_file ~mode:Lwt_io.Output tmp (fun oc ->
          Lwt_io.write oc (Manifest.to_string state))
    in
    Lwt_unix.rename tmp path

  let delete_manifest key =
    Local.delete_manifest ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix key

  (* ── Dirty tracking ────────────────────────────────────────────────────── *)

  let is_dirty key = Hashtbl.mem dirty_keys key
  let set_dirty key = Hashtbl.replace dirty_keys key ()
  let clear_dirty key = Hashtbl.remove dirty_keys key

  (* ── Upload / download ─────────────────────────────────────────────────── *)

  let upload ?cancel key =
    let lp = local_path key in
    let* st = Lwt_unix.stat lp in
    let mtime = st.Unix.st_mtime in
    let* state = R.upload ~key ~src_path:lp ~mtime ?cancel () in
    (* Cancelled while finishing (e.g. renamed away mid-upload): the local
       sidecar under this name has already been moved; writing it back would
       resurrect a ghost entry. *)
    (match cancel with Some c when !c -> raise Backend.Cancelled | _ -> ());
    let* () = write_manifest key state in
    clear_dirty key;
    Lwt.return_unit

  let download key =
    let lp = local_path key in
    let* () = Local.ensure_parent_dir lp in
    let* manifest = read_manifest key in
    match manifest with
      | Some (`Clean manifest) -> R.download_chunks ~dst_path:lp manifest
      | _ -> (
          let* res = R.download ~key ~dst_path:lp in
          match res with
            | None -> Lwt.return_unit
            | Some state -> write_manifest key state)

  let ensure_cached key =
    let* cached = is_cached key in
    if cached then Lwt.return_unit
    else (
      match Hashtbl.find_opt downloading key with
        | Some p -> p
        | None ->
            let p =
              Lwt.finalize
                (fun () ->
                  let* () =
                    Lwt_pool.use download_pool (fun () -> download key)
                  in
                  incr downloads_completed;
                  Lwt.return_unit)
                (fun () ->
                  Hashtbl.remove downloading key;
                  Lwt.return_unit)
            in
            Hashtbl.replace downloading key p;
            p)

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
    let* mst = stat_opt mp in
    match mst with
      | None -> Lwt.return_none
      | Some { Unix.LargeFile.st_kind = Unix.S_DIR; _ } ->
          Lwt.return_some (dir_stat ())
      | Some _ -> (
          let* m = read_manifest key in
          match m with
            | Some `Dirty -> stat_opt (local_path key)
            | Some (`Clean m) ->
                Lwt.return_some (file_stat m.Manifest.size m.Manifest.mtime)
            | None -> Lwt.return_none)

  let stat key =
    let* st = stat key in
    match st with
      | Some _ -> Lwt.return st
      | None -> (
          (* No local sidecar (never cached, or after a full resync): the file's
             manifest still lives on the backend. Resolve it so getattr/stat report
             the real logical size instead of ENOENT. ponytail: one HEAD+GET per cold
             stat; add a sidecar-on-stat cache if cold `ls -l` over a big directory
             gets slow. *)
          let+ m = R.fetch_manifest ~key () in
          match m with
            | Some (`Clean m) ->
                Some (file_stat m.Manifest.size m.Manifest.mtime)
            | _ -> None)

  let list_dir key =
    Local.list_dir ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix key

  (* ── Xattrs ────────────────────────────────────────────────────────────── *)

  let xattrs key =
    let+ m = read_manifest key in
    match m with
      | Some (`Clean m) ->
          [
            ("tsync.h1", m.Manifest.h1);
            ("tsync.h2", m.Manifest.h2);
            ("tsync.size", Int64.to_string m.Manifest.size);
            ("tsync.chunks", string_of_int (List.length m.Manifest.chunks));
          ]
      | _ -> []

  let mark_dirty key =
    if is_dirty key then Lwt.return_unit
    else
      let* () = write_manifest key `Dirty in
      set_dirty key;
      Lwt.return_unit

  (* ── Open-handle tracking ──────────────────────────────────────────────── *)

  let open_count : (string, int) Hashtbl.t = Hashtbl.create 64

  let mark_open key =
    let n = Option.value ~default:0 (Hashtbl.find_opt open_count key) in
    Hashtbl.replace open_count key (n + 1)

  let mark_closed key =
    let n = Option.value ~default:0 (Hashtbl.find_opt open_count key) in
    let n' = max 0 (n - 1) in
    if n' = 0 then Hashtbl.remove open_count key
    else Hashtbl.replace open_count key n';
    n'

  let is_open key =
    Option.value ~default:0 (Hashtbl.find_opt open_count key) > 0

  (* ── Metrics ───────────────────────────────────────────────────────────── *)

  let downloading_count () = Hashtbl.length downloading
  let dirty_count () = Hashtbl.length dirty_keys
  let open_files_count () = Hashtbl.length open_count
  let downloads_completed_count () = !downloads_completed

  (* ── Local eviction ────────────────────────────────────────────────────── *)

  let evict key =
    Local.evict ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix key

  let clear_local key =
    let* () = evict key in
    let* () = delete_manifest key in
    clear_dirty key;
    Lwt.return_unit

  let create key =
    let* () = ensure_parent_dir key in
    let* () =
      Lwt.catch
        (fun () ->
          Lwt_io.with_file ~mode:Lwt_io.Output (local_path key) (fun _ ->
              Lwt.return_unit))
        (fun exn ->
          Log.err "File.create %s: %s" key (Printexc.to_string exn);
          Lwt.fail exn)
    in
    let* () = write_manifest key `Dirty in
    set_dirty key;
    Lwt.return_unit

  let read key (buf : buffer) ~offset =
    let* cached = is_cached key in
    if not cached then
      Log.debug "read %s: not in local cache, fetching from backend" key;
    let* () = ensure_cached key in
    Local_io.read (local_path key) buf ~offset

  let write key (buf : buffer) ~offset =
    let* () = mark_dirty key in
    Local_io.write (local_path key) buf ~offset

  let cancel_upload key = Sq.cancel_put key

  let truncate key size =
    ignore (cancel_upload key);
    let* () = ensure_cached key in
    let lp = local_path key in
    let* fd = Lwt_unix.openfile lp [Unix.O_WRONLY] 0o644 in
    let* () = Lwt_unix.LargeFile.ftruncate fd size in
    let* () = Lwt_unix.close fd in
    mark_dirty key

  let rename_local ~src ~dst =
    let* cached = is_cached src in
    let* () =
      if cached then Lwt_unix.rename (local_path src) (local_path dst)
      else Lwt.return_unit
    in
    Local.rename_manifest ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix ~src_key:src ~dst_key:dst

  (* ── Synchronous backend operations ────────────────────────────────────── *)

  let with_journal key ops s3_op =
    let ek = J.entry_key () in
    let* () = J.write_local_pending ~entry_key:ek ops in
    (* The pending entry is for crash recovery. A synchronous failure is
       reported to the caller instead; keeping the entry would make
       recover_pending_ops replay a known-failed op at every startup. *)
    let* () =
      Lwt.catch s3_op (fun exn ->
          let* () = J.delete_local_pending ~entry_key:ek in
          Lwt.fail exn)
    in
    let* (_ : string) = Fs.write_journal_entry ~entry_key:ek ops in
    let* () = Fs.bump_cursor ek in
    J.delete_local_pending ~entry_key:ek

  let save_version key =
    if C.versioning then
      Versioning.save ~backends:C.backends ~domain_prefix:C.domain_prefix
        ~versions_prefix:C.versions_prefix ~key
    else Lwt.return_unit

  let apply_delete key =
    let* () = save_version key in
    let* () =
      Lwt_list.iter_s
        (fun (module B : Backend.S) -> B.delete ~key ())
        C.backends
    in
    clear_local key

  (* ── Async upload queue ────────────────────────────────────────────────── *)

  let queue_put key =
    let lp = local_path key in
    let* st = stat_opt lp in
    match st with
      | None ->
          Log.err "queue_put %s: local file missing, skipping" key;
          Lwt.return_unit
      | Some { Unix.LargeFile.st_size = size; _ } ->
          let ek = J.entry_key () in
          let ops = [`Put (rel_key key, size)] in
          let+ () = J.write_local_pending ~entry_key:ek ops in
          Sq.post ~key ~entry_key:ek ~ops

  let delete key =
    with_meta (fun () ->
        ignore (cancel_upload key);
        with_journal key [`Delete (rel_key key)] (fun () -> apply_delete key))

  let mkdir key =
    with_meta (fun () ->
        let* () =
          Local.create_dir ~cache_root:C.cache_root ~domain_name:C.domain_name
            ~domain_prefix:C.domain_prefix key
        in
        with_journal key
          [`Mkdir (rel_key key)]
          (fun () -> Fs.create_directory ~key))

  let rmdir key =
    with_meta (fun () ->
        let* () =
          Local.delete_dir ~cache_root:C.cache_root ~domain_name:C.domain_name
            ~domain_prefix:C.domain_prefix key
        in
        with_journal key
          [`Rmdir (rel_key key)]
          (fun () -> Fs.delete_dir ~prefix:key))

  (* Publish an already-chunked file under [key]: its chunks are on the
     backend, only the manifest key and a journal entry are missing. *)
  let publish_manifest key (state : Manifest.state) =
    match state with
      | `Dirty -> Lwt.return_unit
      | `Clean m ->
          let* () =
            Lwt_list.iter_s
              (fun (module B : Backend.S) ->
                B.put ~key ~data:(Manifest.to_string state) ())
              C.backends
          in
          let* ek =
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

  let rename_body ~src ~dst =
    let mp = manifest_path src in
    let* mst = stat_opt mp in
    let is_dir =
      match mst with
        | Some { Unix.LargeFile.st_kind = Unix.S_DIR; _ } -> true
        | _ -> false
    in
    let src = if is_dir then src ^ "/" else src in
    let dst = if is_dir then dst ^ "/" else dst in
    let src_was_uploading = cancel_upload src in
    ignore (cancel_upload dst);
    let* size =
      if not is_dir then
        let* cached = is_cached src in
        if cached then
          let+ st = stat_opt (local_path src) in
          Option.map (fun s -> s.Unix.LargeFile.st_size) st
        else Lwt.return_none
      else Lwt.return_none
    in
    let* () = rename_local ~src ~dst in
    let* dst_cached = is_cached dst in
    if src_was_uploading && dst_cached then queue_put dst
    else
      let* () = if not is_dir then save_version src else Lwt.return_unit in
      let rename_op =
        `Rename Journal.{ dst = rel_key dst; src = rel_key src; size; is_dir }
      in
      Lwt.catch
        (fun () ->
          with_journal dst [rename_op] (fun () ->
              if is_dir then Fs.rename_directory ~src_prefix:src ~dst_prefix:dst
              else Fs.rename_file ~src_key:src ~dst_key:dst))
        (fun exn ->
          (* src is gone from the backend: another client renamed or deleted it
             concurrently. The file already moved locally; publish it as a new,
             conflict-marked file instead, its chunks are still on the backend. *)
          let* src_head =
            if is_dir then Lwt.return_some ()
            else
              let+ h = Fs.head_opt ~key:src in
              Option.map (fun _ -> ()) h
          in
          if is_dir || Option.is_some src_head then Lwt.fail exn
          else
            let* m = read_manifest dst in
            match m with
              | Some (`Clean _ as state) ->
                  (* src was fully uploaded but has since vanished remotely:
                     another client moved or deleted it. Keep both versions by
                     publishing ours under a conflict-marked name. *)
                  let conflict =
                    C.domain_prefix ^ conflict_name (rel_key dst)
                  in
                  let* () = rename_local ~src:dst ~dst:conflict in
                  publish_manifest conflict state
              | Some `Dirty ->
                  (* src never made it to the backend (upload still pending or
                     failed): this is just a rename before first upload, not a
                     conflict. Upload the file under its new name — renaming it
                     to a conflict name here breaks the writer's own follow-up
                     accesses (e.g. rclone stat'ing its renamed .partial). *)
                  let* dst_cached = is_cached dst in
                  if dst_cached then queue_put dst else Lwt.fail exn
              | _ -> Lwt.fail exn)

  let rename ~src ~dst = with_meta (fun () -> rename_body ~src ~dst)

  (* ── Versioning restore ────────────────────────────────────────────────── *)

  let latest_version primary dir =
    let (module B : Backend.S) = primary in
    let+ entries = B.list_all ~prefix:dir () in
    List.fold_left
      (fun acc (e : Backend.file_entry) ->
        match Versioning.parse ~versions_prefix:C.versions_prefix e.key with
          | None -> acc
          | Some (_, ts) -> (
              let n = Int64.of_string ts in
              match acc with
                | Some (_, best) when Int64.compare best n >= 0 -> acc
                | _ -> Some (e.key, n)))
      None entries

  let revert_body ?version key =
    let (module B : Backend.S) =
      match C.backends with
        | b :: _ -> b
        | [] -> failwith "no backends configured"
    in
    let dir =
      Versioning.version_dir ~s3_key:key ~domain_prefix:C.domain_prefix
        ~versions_prefix:C.versions_prefix
    in
    let* src_key =
      match version with
        | Some ts -> Lwt.return (dir ^ ts)
        | None -> (
            let* latest = latest_version (module B) dir in
            match latest with
              | Some (k, _) -> Lwt.return k
              | None -> failwith ("no versions for " ^ rel_key key))
    in
    let* data = B.get ~key:src_key () in
    match Manifest.of_string data with
      | `Dirty -> failwith "cannot restore a dirty version"
      | `Clean m ->
          ignore (cancel_upload key);
          let* () =
            Lwt_list.iter_s
              (fun (module B : Backend.S) -> B.put ~key ~data ())
              C.backends
          in
          let* () = write_manifest key (`Clean m) in
          (* Dataless: keep the manifest sidecar, drop any cached content so the
             restored bytes are fetched lazily on next open. *)
          let* () = evict key in
          clear_dirty key;
          let* ek =
            Fs.write_journal_entry [`Put (rel_key key, m.Manifest.size)]
          in
          Fs.bump_cursor ek

  let revert ?version key = with_meta (fun () -> revert_body ?version key)

  (* ── Foreign op application (sync) ────────────────────────────────────── *)

  let apply_one op =
    Lwt.catch
      (fun () ->
        match op with
          | `Put (rel, _) ->
              let key = C.domain_prefix ^ rel in
              if (not (is_dirty key)) && not (is_open key) then (
                ignore (cancel_upload key);
                let* m = R.fetch_manifest ~key () in
                match m with
                  | None -> Lwt.return_unit
                  | Some state ->
                      let* () = write_manifest key state in
                      evict key)
              else Lwt.return_unit
          | `Delete rel ->
              let key = C.domain_prefix ^ rel in
              if (not (is_dirty key)) && not (is_open key) then (
                ignore (cancel_upload key);
                clear_local key)
              else Lwt.return_unit
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
              let* exists = Lwt_unix.file_exists (manifest_path src_key) in
              if exists && (not (is_dirty src_key)) && not (is_open src_key)
              then rename_local ~src:src_key ~dst:dst_key
              else Lwt.return_unit
          | `Rename { Journal.src; dst; is_dir = false; _ } ->
              let src_key = C.domain_prefix ^ src in
              let dst_key = C.domain_prefix ^ dst in
              let* exists = Lwt_unix.file_exists (manifest_path src_key) in
              if exists && (not (is_dirty src_key)) && not (is_open src_key)
              then rename_local ~src:src_key ~dst:dst_key
              else if (not (is_dirty dst_key)) && not (is_open dst_key) then
                (* No local copy of src (e.g. we renamed it ourselves and
                   published the result): adopt the remote state of dst. *)
                let* m = R.fetch_manifest ~key:dst_key () in
                match m with
                  | Some (`Clean _ as state) -> write_manifest dst_key state
                  | _ -> Lwt.return_unit
              else Lwt.return_unit)
      (fun exn ->
        Log.err "apply_foreign_ops: %s" (Printexc.to_string exn);
        Lwt.return_unit)

  let apply_foreign_ops ops =
    with_meta (fun () -> Lwt_list.iter_s apply_one ops)
end
