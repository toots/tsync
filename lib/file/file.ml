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
  val upload : ?cancel:bool ref -> t -> unit Lwt.t
  val ensure_cached : t -> unit Lwt.t

  (** Prepare a not-yet-complete file for reading: demand-page it (sparse file,
      no download) when it is a real chunked file, else fall back to a whole
      download. Idempotent. *)
  val prepare_read : t -> unit Lwt.t

  (** Ensure the bytes in the range [offset, offset+len] are on disk, fetching
      only the chunks that back them for a partial file. *)
  val ensure_readable : t -> offset:int64 -> len:int -> unit Lwt.t

  (** Mark the chunks a write at the range [offset, offset+len] touches dirty,
      fetching a partially-overwritten absent chunk first (read-modify-write).
  *)
  val dirty_range : t -> offset:int64 -> len:int -> unit Lwt.t

  val stat : t -> Unix.LargeFile.stats option Lwt.t
  val readlink : t -> string option Lwt.t
  val list_dir : t -> string list Lwt.t

  val list_directory :
    prefix:string ->
    (Backend.file_entry list * (string * float option) list) Lwt.t

  val list_all_files : prefix:string -> Backend.file_entry list Lwt.t
  val mark_dirty : t -> unit Lwt.t
  val mark_open : t -> unit
  val mark_closed : t -> int

  (** Last-handle-close policy: queue a dirty file for upload, drop a file
      flagged for eviction, else persist. Decrements the open count. *)
  val release : t -> unit Lwt.t

  (** Evict [key] now if closed, else defer the eviction to its last close. *)
  val request_evict : t -> unit Lwt.t

  (** Best-effort: while local cache usage exceeds [C.max_cache], evict the
      coldest closed, clean files until back under. No-op when [max_cache] is
      unset. *)
  val enforce_cache_cap : unit -> unit Lwt.t

  val downloading_count : unit -> int
  val dirty_count : unit -> int
  val open_files_count : unit -> int
  val downloads_completed_count : unit -> int
  val download_progress : t -> (int * int) option
  val evict : t -> unit Lwt.t
  val create : t -> unit Lwt.t
  val read : t -> buffer -> offset:int64 -> int Lwt.t
  val write : t -> buffer -> offset:int64 -> int Lwt.t
  val cancel_upload : t -> bool
  val truncate : t -> int64 -> unit Lwt.t
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

  val symlink : target:string -> t -> unit Lwt.t
  val apply_foreign_ops : Journal.op list -> unit Lwt.t
end

module Make_with_layout (C : Conf.S) (Sq : Sync_queue.S) (L : Layout.S) : S =
struct
  module J = Journal.Make (C)
  module Fs = File_store.Make (C)
  module R = Remote.Make_with_layout (C) (L)

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

  (* Manifest backend I/O goes through [St], keyed by logical (real-path) keys;
     the layout scheme maps them to backend keys. *)
  module St = Store.Make (C) (L)

  (* Raw presence of the local data file, regardless of completeness. *)
  let data_exists key =
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
        let+ st = Lwt_unix_retry.LargeFile.stat path in
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
    Local.write_manifest ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix key (Manifest.to_string state)

  let delete_manifest key =
    Local.delete_manifest ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix key

  let residency_complete = function
    | None -> true
    | Some a -> Array.for_all (fun s -> s = Manifest.Present) a

  (* ── Dirty tracking ────────────────────────────────────────────────────── *)

  let is_dirty key = Hashtbl.mem dirty_keys key
  let set_dirty key = Hashtbl.replace dirty_keys key ()
  let clear_dirty key = Hashtbl.remove dirty_keys key

  (* ── Upload / download ─────────────────────────────────────────────────── *)

  let upload ?cancel key =
    let lp = local_path key in
    let* st = Lwt_unix_retry.stat lp in
    let mtime = st.Unix.st_mtime in
    (* An edited existing file carries per-chunk residency: only its dirty chunks
       are read/hashed/uploaded; the rest reuse their prior entries (their objects
       are already on the backend, and their bytes may be holes on disk). A
       brand-new or fully-cached file has no residency and is uploaded whole. *)
    let* m = read_manifest key in
    let states =
      match m with Some (`Clean man) -> man.Manifest.residency | _ -> None
    in
    (* Re-upload an edited file at its own chunk size (so reused entries stay
       aligned); a brand-new file uses the domain's configured size. *)
    let chunk_size =
      match m with
        | Some (`Clean man) -> man.Manifest.chunk_size
        | _ -> C.chunk_size
    in
    let reuse =
      match (m, states) with
        | Some (`Clean man), Some states ->
            let entries = Array.of_list man.Manifest.chunks in
            fun i ->
              if
                i < Array.length states
                && states.(i) <> Manifest.Dirty
                && i < Array.length entries
              then Some entries.(i)
              else None
        | _ -> fun _ -> None
    in
    let* state =
      R.upload ~key ~src_path:lp ~mtime ~chunk_size ~reuse ?cancel ()
    in
    (* Cancelled while finishing (e.g. renamed away mid-upload): the local
       sidecar under this name has already been moved; writing it back would
       resurrect a ghost entry. *)
    (match cancel with Some c when !c -> raise Backend.Cancelled | _ -> ());
    (* The backend manifest is fully clean; the local sidecar keeps the file's
       residency — dirty chunks are now Present (uploaded, on disk), absent chunks
       stay absent (still holes) — collapsing to a plain manifest only once every
       chunk is present. *)
    let local_state =
      match (states, state) with
        | Some old, `Clean pub ->
            let states =
              Array.map
                (fun s -> if s = Manifest.Dirty then Manifest.Present else s)
                old
            in
            if residency_complete (Some states) then `Clean pub
            else `Clean { pub with Manifest.residency = Some states }
        | _ -> state
    in
    let* () = write_manifest key local_state in
    clear_dirty key;
    Lwt.return_unit

  let download key =
    let lp = local_path key in
    let* () = Local.ensure_parent_dir lp in
    let* manifest = read_manifest key in
    match manifest with
      | Some (`Clean manifest) -> R.download_chunks ~key ~dst_path:lp manifest
      | _ -> (
          let* res = R.download ~key ~dst_path:lp in
          match res with
            | None -> Lwt.return_unit
            | Some state -> write_manifest key state)

  (* ── Demand-paged residency ────────────────────────────────────────────────
     While a file is open, its per-chunk residency lives in this in-memory view
     and is written through to the sidecar on every change (so it is durable and
     visible to stat/is_cached/recheck across processes and crashes). The local
     data file is sparse: [Present]/[Dirty] chunks are real bytes, [Absent] ones
     are holes. [chunks] holds the real entry for present/absent chunks (an absent
     chunk is fetched by its entry's chunk key) and a blank placeholder for dirty
     chunks (their hash is recomputed at upload). *)
  type view = {
    mutable size : int64;
    chunk_size : int;
    mutable chunks : Manifest.chunk_entry array;
    mutable states : Manifest.chunk_st array;
    mutable fetching : unit Lwt.t option array;
    name : string;
    mutable mtime : float;
    base_h1 : string;
    base_h2 : string;
    mutable last_read_end : int;
        (** end offset of the previous read, for read-ahead *)
  }

  let views : (string, view) Hashtbl.t = Hashtbl.create 64
  let is_partial key = Hashtbl.mem views key
  let blank_entry i size = { Manifest.index = i; h1 = ""; h2 = ""; size }

  (* A file is fully cached when every chunk is present locally. While open the
     in-memory view is authoritative (and cheaper than a sidecar read); otherwise
     it comes from the sidecar residency. A [`Dirty] sidecar (brand-new file) or
     a missing sidecar means the local data is complete. *)
  let is_cached key =
    match Hashtbl.find_opt views key with
      | Some v ->
          Lwt.return (Array.for_all (fun s -> s = Manifest.Present) v.states)
      | None -> (
          let* exists = data_exists key in
          if not exists then Lwt.return_false
          else
            let* m = read_manifest key in
            match m with
              | Some (`Clean m) ->
                  Lwt.return (residency_complete m.Manifest.residency)
              | _ -> Lwt.return_true)

  let num_chunks_for size cs =
    let s = Int64.to_int size in
    if s = 0 then 1 else (s + cs - 1) / cs

  let chunk_len v i =
    max 0 (min v.chunk_size (Int64.to_int v.size - (i * v.chunk_size)))

  (* The sidecar manifest mirroring a view: a plain [`Clean] manifest once every
     chunk is present (recomputing the whole-file digest), otherwise carrying the
     residency array. *)
  let view_state v =
    if Array.for_all (fun s -> s = Manifest.Present) v.states then (
      let entries = Array.to_list v.chunks in
      let h1, h2 = Manifest.digest_of_chunks entries in
      `Clean
        {
          Manifest.v = Manifest.current_version;
          name = v.name;
          size = v.size;
          chunk_size = v.chunk_size;
          chunks = entries;
          h1;
          h2;
          mtime = v.mtime;
          symlink = None;
          residency = None;
        })
    else
      `Clean
        {
          Manifest.v = Manifest.current_version;
          name = v.name;
          size = v.size;
          chunk_size = v.chunk_size;
          chunks = Array.to_list v.chunks;
          h1 = v.base_h1;
          h2 = v.base_h2;
          mtime = v.mtime;
          symlink = None;
          residency = Some (Array.copy v.states);
        }

  (* Persist only while [v] is still the installed view for [key]: a background
     read-ahead that finishes after the file was closed/evicted (its view dropped
     or replaced) must not resurrect residency for data that is now gone. *)
  let persist_view key v =
    match Hashtbl.find_opt views key with
      | Some cur when cur == v -> write_manifest key (view_state v)
      | _ -> Lwt.return_unit

  (* Build (or resume) the in-memory view for [key] from its manifest [man].
     No local data → all chunks [Absent] + sparse-allocate (sidecar written first
     so a crash can never leave the holes looking complete). Data present with
     recorded residency → resume it. Data present, no residency → a fully-cached
     file now tracked per chunk (all [Present]). *)
  let load_view key (man : Manifest.t) =
    let cs = man.Manifest.chunk_size in
    let n = List.length man.Manifest.chunks in
    let chunks = Array.make (max 1 n) (blank_entry 0 0) in
    List.iter
      (fun (c : Manifest.chunk_entry) ->
        if c.index < n then chunks.(c.index) <- c)
      man.Manifest.chunks;
    let* exists = data_exists key in
    let resume =
      match man.Manifest.residency with
        | Some a -> Array.length a = n
        | None -> false
    in
    let states =
      if not exists then Array.make n Manifest.Absent
      else if resume then Array.copy (Option.get man.Manifest.residency)
      else Array.make n Manifest.Present
    in
    let v =
      {
        size = man.Manifest.size;
        chunk_size = cs;
        chunks;
        states;
        fetching = Array.make (max 1 n) None;
        name = man.Manifest.name;
        mtime = man.Manifest.mtime;
        base_h1 = man.Manifest.h1;
        base_h2 = man.Manifest.h2;
        last_read_end = -1;
      }
    in
    Hashtbl.replace views key v;
    (* Resuming a file whose residency still records dirty chunks (e.g. after a
       crash): re-arm the file-level dirty flag so its next close re-queues the
       pending upload. *)
    if Array.exists (fun s -> s = Manifest.Dirty) states then set_dirty key;
    let* () =
      if exists then Lwt.return_unit
      else
        let* () = ensure_parent_dir key in
        let* () = persist_view key v in
        let* fd =
          Lwt_unix_retry.openfile (local_path key)
            [Unix.O_WRONLY; Unix.O_CREAT]
            0o644
        in
        let* () = Lwt_unix_retry.LargeFile.ftruncate fd v.size in
        Lwt_unix_retry.close fd
    in
    Lwt.return v

  (* Fetch chunk [i] to disk (once; concurrent readers share the GET), leaving it
     [Present] in the in-memory view. The sidecar is written by the caller once
     the whole requested range is in — a chunk fetched but not yet persisted is
     simply re-fetched after a crash, never read as a hole. *)
  let fetch_chunk key v i =
    match v.states.(i) with
      | Manifest.Present | Manifest.Dirty -> Lwt.return_unit
      | Manifest.Absent -> (
          match v.fetching.(i) with
            | Some t -> t
            | None ->
                let t =
                  Lwt.finalize
                    (fun () ->
                      let* () =
                        R.download_chunk ~dst_path:(local_path key)
                          ~chunk_size:v.chunk_size ~chunk:v.chunks.(i)
                      in
                      v.states.(i) <- Manifest.Present;
                      Lwt.return_unit)
                    (fun () ->
                      v.fetching.(i) <- None;
                      Lwt.return_unit)
                in
                v.fetching.(i) <- Some t;
                t)

  (* Fetch every [Absent] chunk in [lo, hi], persisting the sidecar once if
     anything was fetched (re-reads of resident ranges touch neither network nor
     disk metadata). *)
  let fetch_span key v lo hi =
    let fetched = ref false in
    let rec go i =
      if i > hi then Lwt.return_unit
      else
        let* () =
          if v.states.(i) = Manifest.Absent then (
            fetched := true;
            fetch_chunk key v i)
          else Lwt.return_unit
        in
        go (i + 1)
    in
    let* () = go lo in
    if !fetched then persist_view key v else Lwt.return_unit

  (* Sequential reads read ahead: after serving a read that continues where the
     last one ended, fetch the next window of chunks in the background so the
     following reads hit disk. Bounded, best-effort, and off for random access. *)
  let readahead_bytes = 4 * 1024 * 1024
  let max_readahead_chunks = 8

  let read_ahead key v ~last =
    let n = Array.length v.chunks in
    let window =
      min max_readahead_chunks (max 1 (readahead_bytes / v.chunk_size))
    in
    let hi = min (n - 1) (last + window) in
    if hi > last then
      Lwt.async (fun () ->
          Lwt.catch
            (fun () -> fetch_span key v (last + 1) hi)
            (fun _ -> Lwt.return_unit))

  let ensure_range key v ~offset ~len =
    let n = Array.length v.chunks in
    if len <= 0 || n = 0 then Lwt.return_unit
    else (
      let cs = v.chunk_size in
      let off = max 0 (Int64.to_int offset) in
      let first = min (off / cs) (n - 1) in
      let last = min ((off + len - 1) / cs) (n - 1) in
      let* () = fetch_span key v first last in
      if off = v.last_read_end then read_ahead key v ~last;
      v.last_read_end <- off + len;
      Lwt.return_unit)

  (* Fetch every outstanding chunk (keeping dirty ones), for whole-file
     materialization (FileProvider fetch, rename). No-op for a non-partial file. *)
  let materialize key =
    let go v =
      let n = Array.length v.chunks in
      let* () =
        Lwt_list.iter_p (fun i -> fetch_chunk key v i) (List.init n Fun.id)
      in
      persist_view key v
    in
    match Hashtbl.find_opt views key with
      | Some v -> go v
      | None -> (
          let* m = read_manifest key in
          match m with
            | Some (`Clean man)
              when man.Manifest.symlink = None
                   && man.Manifest.chunks <> []
                   && man.Manifest.residency <> None ->
                let* v = load_view key man in
                go v
            | _ -> Lwt.return_unit)

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
                    Lwt_pool.use download_pool (fun () ->
                        let* m = read_manifest key in
                        match m with
                          | Some (`Clean man)
                            when man.Manifest.symlink = None
                                 && man.Manifest.chunks <> []
                                 && man.Manifest.residency <> None ->
                              materialize key
                          | _ -> download key)
                  in
                  incr downloads_completed;
                  Lwt.return_unit)
                (fun () ->
                  Hashtbl.remove downloading key;
                  Lwt.return_unit)
            in
            Hashtbl.replace downloading key p;
            p)

  (* Prepare a not-yet-complete file for reading: demand-page it (sparse file +
     residency, no download) when it is a real chunked file, else fall back to a
     whole download (symlink / malformed). Idempotent. *)
  let prepare_read key =
    if is_partial key then Lwt.return_unit
    else
      let* cached = is_cached key in
      if cached then Lwt.return_unit
      else
        let* m = resolved_manifest key in
        match m with
          | Some (`Clean man)
            when man.Manifest.symlink = None && man.Manifest.chunks <> [] ->
              let+ (_ : view) = load_view key man in
              ()
          | _ -> ensure_cached key

  let ensure_readable key ~offset ~len =
    match Hashtbl.find_opt views key with
      | Some v -> ensure_range key v ~offset ~len
      | None ->
          let* cached = is_cached key in
          if cached then Lwt.return_unit else ensure_cached key

  let mark_dirty key =
    if is_dirty key then Lwt.return_unit
    else
      let* () = write_manifest key `Dirty in
      set_dirty key;
      Lwt.return_unit

  let grow_view v n =
    let old = Array.length v.chunks in
    if n > old then begin
      let chunks = Array.make n (blank_entry 0 0) in
      Array.blit v.chunks 0 chunks 0 old;
      let states = Array.make n Manifest.Dirty in
      Array.blit v.states 0 states 0 old;
      let fetching = Array.make n None in
      Array.blit v.fetching 0 fetching 0 old;
      v.chunks <- chunks;
      v.states <- states;
      v.fetching <- fetching
    end

  (* Mark the chunks a write at the range [offset, offset+len] touches [Dirty], fetching a
     chunk first only when the write partially covers an already-existing absent
     chunk (read-modify-write). Fully-covered and grown chunks need no fetch —
     their bytes come from the write (or are sparse zeros). *)
  let apply_dirty key v ~offset ~len =
    let cs = v.chunk_size in
    let off = Int64.to_int offset in
    let endp = off + len in
    let orig_n = Array.length v.chunks in
    let new_size = Int64.of_int (max (Int64.to_int v.size) endp) in
    if new_size > v.size then v.size <- new_size;
    grow_view v (num_chunks_for v.size cs);
    let first = off / cs in
    let last = (endp - 1) / cs in
    let rec go i =
      if i > last then Lwt.return_unit
      else (
        let cstart = i * cs in
        let cend = min ((i + 1) * cs) (Int64.to_int v.size) in
        let fully = off <= cstart && endp >= cend in
        let* () =
          if (not fully) && i < orig_n && v.states.(i) = Manifest.Absent then
            fetch_chunk key v i
          else Lwt.return_unit
        in
        v.states.(i) <- Manifest.Dirty;
        v.chunks.(i) <- blank_entry i (chunk_len v i);
        go (i + 1))
    in
    let* () = go first in
    set_dirty key;
    persist_view key v

  let dirty_range key ~offset ~len =
    match Hashtbl.find_opt views key with
      | Some v -> apply_dirty key v ~offset ~len
      | None -> (
          let* m = read_manifest key in
          match m with
            | Some (`Clean man)
              when man.Manifest.symlink = None && man.Manifest.chunks <> [] ->
                let* v = load_view key man in
                apply_dirty key v ~offset ~len
            | _ -> mark_dirty key)

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

  let symlink_stat size mtime =
    let now = Unix.gettimeofday () in
    Unix.LargeFile.
      {
        st_dev = 0;
        st_ino = 0;
        st_kind = Unix.S_LNK;
        st_perm = 0o777;
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
            | Some (`Clean { Manifest.symlink = Some target; mtime; _ }) ->
                let size = Int64.of_int (String.length target) in
                Lwt.return_some (symlink_stat size mtime)
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
            | Some (`Clean { Manifest.symlink = Some target; mtime; _ }) ->
                let size = Int64.of_int (String.length target) in
                Some (symlink_stat size mtime)
            | Some (`Clean m) ->
                Some (file_stat m.Manifest.size m.Manifest.mtime)
            | _ -> None)

  let readlink key =
    let* m = read_manifest key in
    match m with
      | Some (`Clean { Manifest.symlink = Some _ as target; _ }) ->
          Lwt.return target
      | Some _ | None -> (
          let+ m = R.fetch_manifest ~key () in
          match m with
            | Some (`Clean { Manifest.symlink = Some _ as target; _ }) -> target
            | _ -> None)

  let list_dir key =
    Local.list_dir ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix key

  (* readdir is served from the local manifest mirror (the source of truth for
     names and structure); the backend holds only hashed keys. Directory mtimes
     are not tracked locally, so they are reported absent. *)
  let list_directory ~prefix =
    let+ files, dirs =
      Local.list_directory ~cache_root:C.cache_root ~domain_name:C.domain_name
        ~domain_prefix:C.domain_prefix ~prefix ()
    in
    (files, List.map (fun d -> (d, (None : float option))) dirs)

  let list_all_files ~prefix =
    Local.list_all ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix ~prefix ()

  (* ── Open-handle tracking ──────────────────────────────────────────────── *)

  let open_count : (string, int) Hashtbl.t = Hashtbl.create 64

  (* Last time each key was opened, the recency signal for cache-cap eviction.
     In-memory only; after a restart the data file's mtime stands in. *)
  let last_access : (string, float) Hashtbl.t = Hashtbl.create 64

  let mark_open key =
    Hashtbl.replace last_access key (Unix.gettimeofday ());
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
  let download_progress key = R.get_download_progress key

  (* ── Local eviction ────────────────────────────────────────────────────── *)

  (* Drop the local data (keeping the sidecar) and any in-memory view. A partial
     sidecar's residency is reset to the plain published form so a reopen starts a
     fresh demand-page rather than resuming against data that is now gone. *)
  let evict key =
    Hashtbl.remove views key;
    Hashtbl.remove last_access key;
    let* m = read_manifest key in
    let* () =
      match m with
        | Some (`Clean man) when man.Manifest.residency <> None ->
            write_manifest key (`Clean { man with Manifest.residency = None })
        | _ -> Lwt.return_unit
    in
    Local.evict ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix key

  (* ── Cache-size cap ─────────────────────────────────────────────────────────
     Best-effort LRU eviction to keep local cache usage under [C.max_cache]. A
     sweep enumerates cached files (via the manifest mirror), sums the bytes each
     actually holds on disk, and — while over the cap — evicts the coldest files
     that are safe to drop (closed, and clean with no dirty chunks; a dirty file's
     data is unsynced and must never be dropped). ponytail: O(files) per sweep;
     add incremental accounting if it ever shows up. *)

  (* Bytes chunk [i] of a file of [size]/[chunk_size] holds when present. *)
  let present_bytes (m : Manifest.t) =
    match m.Manifest.residency with
      | None -> Int64.to_int m.Manifest.size
      | Some states ->
          let cs = m.Manifest.chunk_size in
          let total = Int64.to_int m.Manifest.size in
          let bytes = ref 0 in
          Array.iteri
            (fun i st ->
              if st <> Manifest.Absent then
                bytes := !bytes + max 0 (min cs (total - (i * cs))))
            states;
          !bytes

  let has_dirty_chunks (m : Manifest.t) =
    match m.Manifest.residency with
      | Some a -> Array.exists (fun s -> s = Manifest.Dirty) a
      | None -> false

  let enforce_cache_cap () =
    match C.max_cache with
      | None -> Lwt.return_unit
      | Some cap ->
          let* rels =
            Local.walk_manifests ~cache_root:C.cache_root
              ~domain_name:C.domain_name ()
          in
          (* (key, bytes-on-disk, evictable, recency) for every cached file. *)
          let* items =
            Lwt_list.filter_map_s
              (fun rel ->
                let key = C.domain_prefix ^ rel in
                let* st = stat_opt (local_path key) in
                match st with
                  | None -> Lwt.return_none (* no local data → no space used *)
                  | Some st ->
                      let mtime = st.Unix.LargeFile.st_mtime in
                      let recency =
                        match Hashtbl.find_opt last_access key with
                          | Some t -> Float.max t mtime
                          | None -> mtime
                      in
                      let+ m = read_manifest key in
                      let bytes, evictable =
                        match m with
                          | Some (`Clean man) ->
                              ( present_bytes man,
                                (not (has_dirty_chunks man))
                                && not (is_open key) )
                          | _ ->
                              (* [`Dirty]/new or unreadable: unsynced, keep. *)
                              (Int64.to_int st.Unix.LargeFile.st_size, false)
                      in
                      Some (key, bytes, evictable, recency))
              rels
          in
          let total =
            List.fold_left (fun acc (_, b, _, _) -> acc + b) 0 items
          in
          if total <= cap then Lwt.return_unit
          else (
            (* Evict coldest-first until under the cap or nothing left to drop. *)
            let candidates =
              List.filter (fun (_, _, e, _) -> e) items
              |> List.sort (fun (_, _, _, a) (_, _, _, b) -> compare a b)
            in
            let rec go total = function
              | [] -> Lwt.return_unit
              | _ when total <= cap -> Lwt.return_unit
              | (key, bytes, _, _) :: rest ->
                  Log.debug "cache cap: evicting %s (%d bytes)" key bytes;
                  let* () = evict key in
                  go (total - bytes) rest
            in
            go total candidates)

  let clear_local key =
    let* () = evict key in
    let* () = delete_manifest key in
    clear_dirty key;
    Lwt.return_unit

  let create key =
    Hashtbl.remove views key;
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
    let* () = prepare_read key in
    let* () = ensure_readable key ~offset ~len:(Bigarray.Array1.dim buf) in
    Local_io.read (local_path key) buf ~offset

  let cancel_upload key = Sq.cancel_put key

  let write key (buf : buffer) ~offset =
    (* An in-flight upload reads the file with pread while we mutate it in
       place: cancel it, or it publishes a manifest for torn content (and its
       completion would clear the dirty flag set below). The writer's release
       re-queues the upload. *)
    ignore (cancel_upload key);
    let* () = dirty_range key ~offset ~len:(Bigarray.Array1.dim buf) in
    Local_io.write (local_path key) buf ~offset

  let truncate_view key v new_size =
    let cs = v.chunk_size in
    let new_n = num_chunks_for new_size cs in
    let old_n = Array.length v.chunks in
    let boundary = new_n - 1 in
    (* The last chunk's byte length changes, so it becomes dirty and must hold
       its current bytes first (fetch it when shrinking into an absent chunk). *)
    let* () =
      if
        boundary >= 0 && boundary < old_n
        && v.states.(boundary) = Manifest.Absent
      then fetch_chunk key v boundary
      else Lwt.return_unit
    in
    let* fd =
      Lwt_unix_retry.openfile (local_path key)
        [Unix.O_WRONLY; Unix.O_CREAT]
        0o644
    in
    let* () = Lwt_unix_retry.LargeFile.ftruncate fd new_size in
    let* () = Lwt_unix_retry.close fd in
    let chunks = Array.make (max 1 new_n) (blank_entry 0 0) in
    let states = Array.make new_n Manifest.Dirty in
    let fetching = Array.make (max 1 new_n) None in
    for i = 0 to new_n - 1 do
      if i < old_n then (
        chunks.(i) <- v.chunks.(i);
        states.(i) <- v.states.(i))
    done;
    v.chunks <- chunks;
    v.states <- states;
    v.fetching <- fetching;
    v.size <- new_size;
    (* the boundary (and any grown) chunk's content changed → dirty *)
    for i = min boundary (old_n - 1) to new_n - 1 do
      if i >= 0 then (
        states.(i) <- Manifest.Dirty;
        chunks.(i) <- blank_entry i (chunk_len v i))
    done;
    set_dirty key;
    persist_view key v

  let truncate key size =
    ignore (cancel_upload key);
    let resize_whole () =
      let* () = ensure_cached key in
      let* fd =
        Lwt_unix_retry.openfile (local_path key)
          [Unix.O_WRONLY; Unix.O_CREAT]
          0o644
      in
      let* () = Lwt_unix_retry.LargeFile.ftruncate fd size in
      let* () = Lwt_unix_retry.close fd in
      mark_dirty key
    in
    match Hashtbl.find_opt views key with
      | Some v -> truncate_view key v size
      | None -> (
          let* m = read_manifest key in
          match m with
            | Some (`Clean man)
              when man.Manifest.symlink = None && man.Manifest.chunks <> [] ->
                let* v = load_view key man in
                truncate_view key v size
            | _ -> resize_whole ())

  let rename_local ~src ~dst =
    Hashtbl.remove views src;
    Hashtbl.remove views dst;
    let* cached = data_exists src in
    let* () =
      if cached then Lwt_unix_retry.rename (local_path src) (local_path dst)
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
    if C.versioning then St.save_version ~key else Lwt.return_unit

  let apply_delete key =
    let* () = save_version key in
    let* () = St.delete_manifest ~key in
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

  (* ── Close / eviction policy ────────────────────────────────────────────── *)

  (* Eviction requested while a file is open is deferred to its last close. *)
  let pending_evict : (string, unit) Hashtbl.t = Hashtbl.create 16

  let request_evict key =
    if is_open key then (
      Hashtbl.replace pending_evict key ();
      Lwt.return_unit)
    else evict key

  (* Last handle closed: a dirty file is queued for upload; a file flagged for
     eviction is dropped; otherwise it just persists (partial files keep their
     sidecar residency and resume on the next open). *)
  let release key =
    let remaining = mark_closed key in
    if remaining > 0 then Lwt.return_unit
    else (
      Hashtbl.remove views key;
      if is_dirty key then (
        clear_dirty key;
        queue_put key)
      else (
        let was_pending = Hashtbl.mem pending_evict key in
        Hashtbl.remove pending_evict key;
        if was_pending then evict key else Lwt.return_unit))

  let delete key =
    with_meta (fun () ->
        ignore (cancel_upload key);
        with_journal key [`Delete (rel_key key)] (fun () -> apply_delete key))

  (* Backend key of a directory's folder marker (under its parent's namespace).
     Used to move/remove a marker whose local dir has already moved or is gone. *)
  let folder_marker_bkey key =
    let rel =
      let r = rel_key key in
      if String.ends_with ~suffix:"/" r then String.sub r 0 (String.length r - 1)
      else r
    in
    let parent = match Filename.dirname rel with "." -> "" | d -> d in
    let+ pid =
      Folder_ids.resolve ~cache_root:C.cache_root ~domain_name:C.domain_name
        parent
    in
    C.domain_prefix ^ Folder.child_key ~folder_id:pid (Filename.basename rel)

  let mkdir key =
    with_meta (fun () ->
        let* () =
          Local.create_dir ~cache_root:C.cache_root ~domain_name:C.domain_name
            ~domain_prefix:C.domain_prefix key
        in
        with_journal key
          [`Mkdir (rel_key key)]
          (fun () -> St.put_folder_marker ~key))

  (* O(1) delete: detach the folder by moving its parent marker into the trash
     namespace. The subtree stays intact on the backend (untouched) for undo and
     is reclaimed by [expire]; the local mirror copy is dropped immediately. *)
  let rmdir key =
    with_meta (fun () ->
        let rel =
          let r = rel_key key in
          if String.ends_with ~suffix:"/" r then
            String.sub r 0 (String.length r - 1)
          else r
        in
        let* old_marker = folder_marker_bkey key in
        let* fid =
          Folder_ids.resolve ~cache_root:C.cache_root ~domain_name:C.domain_name
            rel
        in
        let trash_key =
          C.domain_prefix ^ Folder.trash_id ^ "/" ^ Folder.new_id ()
        in
        let marker =
          Folder.trash_marker_to_string ~name:(Filename.basename rel) ~id:fid
            ~path:rel
        in
        let* () =
          with_journal key
            [`Rmdir (rel_key key)]
            (fun () ->
              let* () = St.put_raw ~bkey:trash_key ~data:marker in
              St.delete_raw ~bkey:old_marker)
        in
        Local.delete_dir ~cache_root:C.cache_root ~domain_name:C.domain_name
          ~domain_prefix:C.domain_prefix key)

  (* Publish an already-chunked file under [key]: its chunks are on the
     backend, only the manifest key and a journal entry are missing. *)
  let publish_manifest key (state : Manifest.state) =
    match state with
      | `Dirty -> Lwt.return_unit
      | `Clean m ->
          Log.info "publish_manifest %s: size=%Ld" key m.Manifest.size;
          let* () = St.put_manifest ~key ~data:(Manifest.to_string state) in
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

  (* A file rename moves its manifest object but not its body, so the leaf [name]
     it records goes stale. Rewrite it (local sidecar + backend) to match the new
     key. A directory rename leaves every descendant's leaf name unchanged, so
     nothing else needs fixing. *)
  let resync_manifest_name key =
    let name = Filename.basename key in
    let* m = read_manifest key in
    match m with
      | Some (`Clean man) when man.Manifest.name <> name ->
          let state = `Clean { man with Manifest.name } in
          let* () = write_manifest key state in
          St.put_manifest ~key ~data:(Manifest.to_string state)
      | _ -> Lwt.return_unit

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
        let* cached = data_exists src in
        if cached then
          let+ st = stat_opt (local_path src) in
          Option.map (fun s -> s.Unix.LargeFile.st_size) st
        else Lwt.return_none
      else Lwt.return_none
    in
    let* () = rename_local ~src ~dst in
    let* dst_cached = data_exists dst in
    if src_was_uploading && dst_cached then queue_put dst
    else
      let* () = if not is_dir then save_version src else Lwt.return_unit in
      let rename_op =
        `Rename Journal.{ dst = rel_key dst; src = rel_key src; size; is_dir }
      in
      Lwt.catch
        (fun () ->
          let* () =
            with_journal dst [rename_op] (fun () ->
                (* A directory's backend keys live under its stable folder id,
                   which travelled with the local [.tsync-dir] marker during
                   [rename_local] — so the subtree needs no backend work; only
                   the parent's folder marker moves. A file's key encodes its
                   leaf, so it is moved and renamed. *)
                if is_dir then
                  let* old_marker = folder_marker_bkey src in
                  let* () = St.delete_raw ~bkey:old_marker in
                  let* () =
                    Local.refresh_dir_marker ~cache_root:C.cache_root
                      ~domain_name:C.domain_name ~domain_prefix:C.domain_prefix
                      dst
                  in
                  St.put_folder_marker ~key:dst
                else Fs.rename_file ~src_key:src ~dst_key:dst)
          in
          if is_dir then Lwt.return_unit else resync_manifest_name dst)
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

  (* Newest version among [entries] (each a [versions/…/<ts>] object), by the
     trailing timestamp component. *)
  let latest_version entries =
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
    let* src_key =
      match version with
        | Some ts ->
            let+ dir = St.version_dir ~key in
            dir ^ ts
        | None -> (
            let* entries = St.list_versions ~key in
            match latest_version entries with
              | Some (k, _) -> Lwt.return k
              | None -> failwith ("no versions for " ^ rel_key key))
    in
    let* data = St.get_version ~vkey:src_key in
    match Manifest.of_string data with
      | `Dirty -> failwith "cannot restore a dirty version"
      | `Clean m ->
          ignore (cancel_upload key);
          let* () = St.put_manifest ~key ~data in
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

  (* Live symlink creation is only meaningful under the [`Keep] policy: a
     [`Follow]/[`Skip] domain must never contain symlink objects, and there is
     no sensible way to "follow" at creation time (the target may be relative,
     dangling, or outside the mount). *)
  let symlink ~target key =
    (match C.symlink_policy with
      | `Keep -> ()
      | `Follow | `Skip -> raise (Unix.Unix_error (Unix.EPERM, "symlink", key)));
    with_meta (fun () ->
        let state =
          Manifest.make_symlink ~name:(Filename.basename key) ~target
            ~mtime:(Unix.gettimeofday ())
        in
        let data = Manifest.to_string state in
        let* () = St.put_manifest ~key ~data in
        let* () = write_manifest key state in
        let size =
          match state with
            | `Clean m -> m.Manifest.size
            | `Dirty -> assert false
        in
        let* ek = Fs.write_journal_entry [`Put (rel_key key, size)] in
        Fs.bump_cursor ek)

  (* ── Foreign op application (sync) ────────────────────────────────────── *)

  (* A folder created on another client already has a backend marker carrying its
     id; adopt that id locally so both machines share one namespace for it.
     Without this, resolving the folder here would mint a *different* id and this
     client's writes (and reads) would land in a separate namespace. *)
  let adopt_folder_id rel =
    let rel =
      if String.ends_with ~suffix:"/" rel then
        String.sub rel 0 (String.length rel - 1)
      else rel
    in
    if rel = "" then Lwt.return_unit
    else (
      let parent = match Filename.dirname rel with "." -> "" | d -> d in
      let* pid =
        Folder_ids.resolve ~cache_root:C.cache_root ~domain_name:C.domain_name
          parent
      in
      let marker_key =
        C.domain_prefix
        ^ Folder.child_key ~folder_id:pid (Filename.basename rel)
      in
      Lwt.catch
        (fun () ->
          let* data = St.get_object ~bkey:marker_key in
          match Folder.marker_of_string data with
            | Some m ->
                Folder_ids.write ~cache_root:C.cache_root
                  ~domain_name:C.domain_name rel
                  { Folder.name = Filename.basename rel; id = m.Folder.id }
            | None -> Lwt.return_unit)
        (fun _ -> Lwt.return_unit))

  (* Failures propagate to the caller: the sync poller must not advance its
     high-water mark past an entry it could not apply, or the op is lost
     until a full resync. *)
  let apply_one op =
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
          let* () =
            Local.create_dir ~cache_root:C.cache_root ~domain_name:C.domain_name
              ~domain_prefix:C.domain_prefix (C.domain_prefix ^ rel)
          in
          adopt_folder_id rel
      | `Rmdir rel ->
          Local.delete_dir ~cache_root:C.cache_root ~domain_name:C.domain_name
            ~domain_prefix:C.domain_prefix (C.domain_prefix ^ rel)
      | `Rename { Journal.src; dst; is_dir = true; _ } ->
          let src_key = C.domain_prefix ^ src in
          let dst_key = C.domain_prefix ^ dst in
          let* exists = Lwt_unix_retry.file_exists (manifest_path src_key) in
          if exists && (not (is_dirty src_key)) && not (is_open src_key) then
            rename_local ~src:src_key ~dst:dst_key
          else Lwt.return_unit
      | `Rename { Journal.src; dst; is_dir = false; _ } ->
          let src_key = C.domain_prefix ^ src in
          let dst_key = C.domain_prefix ^ dst in
          let* exists = Lwt_unix_retry.file_exists (manifest_path src_key) in
          if exists && (not (is_dirty src_key)) && not (is_open src_key) then
            rename_local ~src:src_key ~dst:dst_key
          else if (not (is_dirty dst_key)) && not (is_open dst_key) then
            (* No local copy of src (e.g. we renamed it ourselves and
                   published the result): adopt the remote state of dst. *)
            let* m = R.fetch_manifest ~key:dst_key () in
            match m with
              | Some (`Clean _ as state) -> write_manifest dst_key state
              | _ -> Lwt.return_unit
          else Lwt.return_unit

  let apply_foreign_ops ops =
    with_meta (fun () -> Lwt_list.iter_s apply_one ops)
end

(* The inode layout is what every path-keyed caller wants. *)
module Make (C : Conf.S) (Sq : Sync_queue.S) =
  Make_with_layout (C) (Sq) (Layout.Inode.Make (C))
