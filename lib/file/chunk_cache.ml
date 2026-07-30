(* The local cache-chunk store: bodies of {!Chunk_group}s, named by a content
   key derived from the stored chunks they hold.

   Nothing here is per-file. A group is present iff its file exists, so there is
   no residency to record and no state that can disagree with the disk — and any
   group may be deleted at any moment, because it can always be fetched again.
   Callers must therefore treat a miss as ordinary (see {!read_into}).

   Content addressing also makes the store shared: two files whose chunks group
   identically hit the same file and share one download. *)

open Lwt.Syntax

(* What the store needs from the backend layer: one stored chunk body by content
   key. Kept to this instead of [Remote.S] so the store has no cycle with it and
   can be driven by a stub in tests. Grouping is invisible to the backend: a
   cache chunk is fetched as its members. *)
module type Fetch = sig
  val get_chunk : chunk_key:string -> string Lwt.t
end

module Make (C : Conf.S) (F : Fetch) = struct
  let path group =
    Cache_layout.chunk_path ~cache_root:C.cache_root ~domain_name:C.domain_name
      (Chunk_group.key group)

  let exists group = Lwt_unix_retry.file_exists (path group)

  (* Downloads in flight, keyed by content: two readers of the same group — in
     the same file or in different ones — share one fetch. *)
  let fetching : (string, unit Lwt.t) Hashtbl.t = Hashtbl.create 64
  let in_flight () = Hashtbl.length fetching

  (* Write the group's body from [body i]. The file is sized on disk up front and
     each member is written at its own offset, so members are produced
     concurrently and land in whatever order they finish: a cold group costs about
     one round trip, whatever [cache_chunk_size] is.

     Concurrency is bounded in the producer. [Remote.get_chunk] takes a slot from
     a pool of [max_downloads] shared by every download in the process, so
     launching all of a group's members at once stays under that ceiling. Resident
     bytes follow the same bound, since a body exists only between its producer
     returning and its write completing.

     Every byte of the file has to be covered exactly once, which
     {!Fs_util.atomic_write_at} requires and the length check enforces: a member
     whose length disagrees with the manifest fails the write, so a wrong-length
     body never reaches a caller as file content. *)
  let write_group group body =
    let p = path group in
    let* () = Fs_util.ensure_parent p in
    (* Atomic: a reader never sees a half-written group, so presence alone is
       proof of a complete body. *)
    Fs_util.atomic_write_at p ~size:(Chunk_group.bytes group) (fun put ->
        Lwt_list.iter_p
          (fun i ->
            let* data = body i in
            let expected = Chunk_group.size group i in
            if String.length data <> expected then
              Lwt.fail
                (Backend.Backend_error
                   (Printf.sprintf "chunk %s: have %d bytes, manifest says %d"
                      (Chunk_group.member_key group i)
                      (String.length data) expected))
            else put ~offset:(Chunk_group.offset group i) data)
          (Chunk_group.indices group))

  let fetch group =
    write_group group (fun i ->
        F.get_chunk ~chunk_key:(Chunk_group.member_key group i))

  (* Put [group]'s body on disk, unless it is already there. Concurrent callers
     await the same fetch; [force] re-fetches a body believed corrupt. *)
  let ensure ?(force = false) ~group () =
    let key = Chunk_group.key group in
    match Hashtbl.find_opt fetching key with
      | Some t -> t
      | None ->
          let t =
            Lwt.finalize
              (fun () ->
                (* The pause is load-bearing: the table entry must be visible to
                   a second caller before this one touches the filesystem, and
                   every step below yields. *)
                let* () = Lwt.pause () in
                let* present =
                  if force then Lwt.return_false else exists group
                in
                if present then Lwt.return_unit else fetch group)
              (fun () ->
                Hashtbl.remove fetching key;
                Lwt.return_unit)
          in
          Hashtbl.replace fetching key t;
          t

  (* Write a group assembled from bytes the caller already holds — the tail of a
     promotion, where every member is a local staged body. Idempotent: a body
     already under this key is the same bytes. *)
  let put_group ~group ~member =
    let* present = exists group in
    if present then Lwt.return_unit else write_group group member

  (* ── Cache cap ─────────────────────────────────────────────────────────────
     Every chunk here is interchangeable and re-fetchable, so keeping the store
     under [C.max_cache] needs no bookkeeping at all: no residency, no open
     counts, no dirty checks. Unsynced data cannot be lost because it does not
     live here — it lives in the staged tree, which this never visits. *)

  let root () = Cache_layout.chunks_dir ~cache_root:C.cache_root C.domain_name

  (* (path, bytes, mtime) for every chunk body, walking the fanout dirs. Each
     directory's entries are stat'd in parallel — the same shape
     {!Local_backend.list_prefix} uses, and for the same reason: a stat per file
     serialized through the Lwt thread pool costs a round trip each, which on a
     cache of a few thousand chunks is the difference between milliseconds and
     seconds. The pool bounds the actual concurrency. *)
  let entries () =
    let* dirs = Fs_util.readdir_list (root ()) in
    let+ per_dir =
      Lwt_list.map_p
        (fun dir ->
          let dir = Filename.concat (root ()) dir in
          let* names = Fs_util.readdir_list dir in
          Lwt_list.filter_map_p
            (fun name ->
              let path = Filename.concat dir name in
              Lwt.catch
                (fun () ->
                  let+ st = Lwt_unix_retry.stat path in
                  Some (path, st.Unix.st_size, st.Unix.st_mtime))
                (fun _ -> Lwt.return_none))
            names)
        dirs
    in
    List.concat per_dir

  let stats () =
    Lwt.catch
      (fun () ->
        let+ items = entries () in
        ( List.length items,
          List.fold_left (fun acc (_, bytes, _) -> acc + bytes) 0 items ))
      (fun _ -> Lwt.return (0, 0))

  (* Delete coldest-first until under the cap. Best-effort: a chunk deleted from
     under an in-flight read is simply fetched again ({!body}). *)
  let enforce_cap () =
    match C.max_cache with
      | None -> Lwt.return_unit
      | Some cap ->
          let* items = Lwt.catch entries (fun _ -> Lwt.return_nil) in
          let total =
            List.fold_left (fun acc (_, bytes, _) -> acc + bytes) 0 items
          in
          if total <= cap then Lwt.return_unit
          else (
            let coldest =
              List.sort (fun (_, _, a) (_, _, b) -> compare a b) items
            in
            let rec go total = function
              | [] -> Lwt.return_unit
              | _ when total <= cap -> Lwt.return_unit
              | (path, bytes, _) :: rest ->
                  Log.debug "chunk cache: dropping %s (%d bytes)"
                    (Filename.basename path) bytes;
                  let* () = Fs_util.unlink_quiet path in
                  go (total - bytes) rest
            in
            go total coldest)

  let forget ~group = Fs_util.unlink_quiet (path group)

  (* One stored chunk's bytes out of a group already on disk, without fetching:
     for a repair that wants to know whether the local copy can stand in. *)
  let member_if_local ~group ~index =
    let len = Chunk_group.size group index in
    Lwt.catch
      (fun () ->
        Lwt_io.with_file ~mode:Lwt_io.Input (path group) (fun ic ->
            let* () =
              Lwt_io.set_position ic
                (Int64.of_int (Chunk_group.offset group index))
            in
            let+ body = Lwt_io.read ~count:len ic in
            if String.length body = len then Some body else None))
      (fun _ -> Lwt.return_none)

  (* Integrity pass over one group: every member segment must hash to the key
     the manifest published it under. The repair is a deletion — the bytes come
     back from the backend on the next read. [false] when the group was
     dropped. *)
  let verify_group ~group =
    let* present = exists group in
    if not present then Lwt.return_true
    else
      let* ok =
        Lwt_list.fold_left_s
          (fun ok index ->
            if not ok then Lwt.return_false
            else
              let+ body = member_if_local ~group ~index in
              match body with
                | None -> false
                | Some body ->
                    Printf.sprintf "%s-%s" (Xxhash.hash_hex body 0)
                      (Xxhash.hash_hex body 1)
                    = Chunk_group.member_key group index)
          true
          (Chunk_group.indices group)
      in
      if ok then Lwt.return_true
      else (
        Log.info "chunk cache: dropping corrupt %s" (Chunk_group.key group);
        let+ () = forget ~group in
        false)

  (* ── Staged bodies ────────────────────────────────────────────────────────
     A chunk being written locally cannot live under a content key — its content
     is still changing, and a published chunk's name *is* its hash. It gets a
     uuid instead, and is renamed under its content key once the upload that
     hashes it succeeds ({!promote}). Staged bodies are unsynced data: nothing
     here ever deletes one behind the writer's back. *)

  let staged_path uuid =
    Filename.concat
      (Cache_layout.staged_chunks_dir ~cache_root:C.cache_root C.domain_name)
      uuid

  (* A new body of [len] zero bytes: sparse, so a grown chunk costs no disk until
     it is written. *)
  let stage_empty ~uuid ~len =
    let p = staged_path uuid in
    let* () = Fs_util.ensure_parent p in
    let* fd =
      Lwt_unix_retry.openfile p
        [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC]
        0o644
    in
    Lwt.finalize
      (fun () -> Lwt_unix_retry.LargeFile.ftruncate fd (Int64.of_int len))
      (fun () -> Lwt_unix_retry.close fd)

  (* A new body holding a published chunk's bytes, for a write that does not
     replace all of them. This copy is the price of immutable content-addressed
     chunks. *)
  let stage_from_chunk ~group ~index ~uuid =
    let* () = ensure ~group () in
    let p = staged_path uuid in
    let* () = Fs_util.ensure_parent p in
    let len = Chunk_group.size group index in
    let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout len in
    let* n =
      Local_io.read (path group) buf
        ~offset:(Int64.of_int (Chunk_group.offset group index))
    in
    let* () = stage_empty ~uuid ~len in
    let+ (_ : int) =
      Local_io.write p (Bigarray.Array1.sub buf 0 n) ~offset:0L
    in
    ()

  let stage_write ~uuid buf ~chunk_off =
    Local_io.write (staged_path uuid) buf ~offset:(Int64.of_int chunk_off)

  let stage_read_into ~uuid buf ~chunk_off =
    Local_io.read (staged_path uuid) buf ~offset:(Int64.of_int chunk_off)

  let stage_truncate ~uuid ~len =
    let* fd =
      Lwt_unix_retry.openfile (staged_path uuid) [Unix.O_WRONLY] 0o644
    in
    Lwt.finalize
      (fun () -> Lwt_unix_retry.LargeFile.ftruncate fd (Int64.of_int len))
      (fun () -> Lwt_unix_retry.close fd)

  let stage_forget ~uuid = Fs_util.unlink_quiet (staged_path uuid)

  (* ── Whole bodies ─────────────────────────────────────────────────────────
     A frontend that hands back a complete file (the FileProvider extension always
     does) gets its file adopted as-is: one file, no chunk split, no copy. *)

  let whole_path uuid =
    Filename.concat
      (Cache_layout.staged_whole_dir ~cache_root:C.cache_root C.domain_name)
      uuid

  (* Take over [src] as the whole body [uuid]. A rename when the two are on one
     filesystem — the point of this path — and a copy when they are not. *)
  let adopt_whole ~src ~uuid =
    let dst = whole_path uuid in
    let* () = Fs_util.ensure_parent dst in
    Lwt.catch
      (fun () -> Lwt_unix_retry.rename src dst)
      (function
        | Unix.Unix_error (Unix.EXDEV, _, _) ->
            let* () = Fs_util.copy_file ~src ~dst in
            Fs_util.unlink_quiet src
        | exn -> Lwt.fail exn)

  let whole_read_into ~uuid buf ~offset =
    Local_io.read (whole_path uuid) buf ~offset

  let whole_forget ~uuid = Fs_util.unlink_quiet (whole_path uuid)

  (* Fill [buf] from stored chunk [index] of [group], starting [chunk_off] bytes
     into that chunk and fetching the group if it is absent. The cap may delete a
     group between the fetch and the read, or even mid-read, so a miss or a short
     read is retried once against a freshly fetched body; a second failure is
     real and raised. *)
  let read_into ~group ~index buf ~chunk_off =
    let want = Bigarray.Array1.dim buf in
    let offset = Int64.of_int (Chunk_group.offset group index + chunk_off) in
    let attempt () = Local_io.read (path group) buf ~offset in
    let refetch () =
      let* () = ensure ~force:true ~group () in
      attempt ()
    in
    let* () = ensure ~group () in
    Lwt.catch
      (fun () ->
        let* n = attempt () in
        if n = want then Lwt.return n else refetch ())
      (function
        | Unix.Unix_error (Unix.ENOENT, _, _) -> refetch ()
        | exn -> Lwt.fail exn)
end
