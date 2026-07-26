(* The local chunk store: bodies of backend chunks, named by their content key.

   Nothing here is per-file. A chunk is present iff its file exists, so there is
   no residency to record and no state that can disagree with the disk — and any
   chunk may be deleted at any moment, because it can always be fetched again.
   Callers must therefore treat a miss as ordinary (see {!read_into}).

   Content addressing also makes the store shared: two files holding the same
   chunk hit the same file and share one download. *)

open Lwt.Syntax

(* What the store needs from the backend layer: one chunk body by content key.
   Kept to this instead of [Remote.S] so the store has no cycle with it and can
   be driven by a stub in tests. *)
module type Fetch = sig
  val get_chunk : chunk_key:string -> string Lwt.t
end

module Make (C : Conf.S) (F : Fetch) = struct
  let path chunk_key =
    Cache_layout.chunk_path ~cache_root:C.cache_root ~domain_name:C.domain_name
      chunk_key

  let exists chunk_key = Lwt_unix_retry.file_exists (path chunk_key)

  (* Downloads in flight, keyed by content: two readers of the same chunk — in
     the same file or in different ones — share one GET. *)
  let fetching : (string, unit Lwt.t) Hashtbl.t = Hashtbl.create 64
  let in_flight () = Hashtbl.length fetching

  let fetch chunk_key =
    let p = path chunk_key in
    let* () = Fs_util.ensure_parent p in
    let* data = F.get_chunk ~chunk_key in
    (* Atomic: a reader never sees a half-written chunk, so presence alone is
       proof of a complete body. *)
    Fs_util.atomic_write p data

  (* Put [chunk_key]'s body on disk, unless it is already there. Concurrent
     callers await the same fetch; [force] re-fetches a body believed corrupt. *)
  let ensure ?(force = false) ~chunk_key () =
    match Hashtbl.find_opt fetching chunk_key with
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
                  if force then Lwt.return_false else exists chunk_key
                in
                if present then Lwt.return_unit else fetch chunk_key)
              (fun () ->
                Hashtbl.remove fetching chunk_key;
                Lwt.return_unit)
          in
          Hashtbl.replace fetching chunk_key t;
          t

  (* ── Cache cap ─────────────────────────────────────────────────────────────
     Every chunk here is interchangeable and re-fetchable, so keeping the store
     under [C.max_cache] needs no bookkeeping at all: no residency, no open
     counts, no dirty checks. Unsynced data cannot be lost because it does not
     live here — it lives in the staged tree, which this never visits. *)

  let root () = Cache_layout.chunks_dir ~cache_root:C.cache_root C.domain_name

  (* (path, bytes, mtime) for every chunk body, walking the fanout dirs. *)
  let entries () =
    let* dirs = Fs_util.readdir_list (root ()) in
    Lwt_list.fold_left_s
      (fun acc dir ->
        let dir = Filename.concat (root ()) dir in
        let* names = Fs_util.readdir_list dir in
        Lwt_list.fold_left_s
          (fun acc name ->
            let path = Filename.concat dir name in
            Lwt.catch
              (fun () ->
                let+ st = Lwt_unix_retry.stat path in
                (path, st.Unix.st_size, st.Unix.st_mtime) :: acc)
              (fun _ -> Lwt.return acc))
          acc names)
      [] dirs

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
                  let* () =
                    Lwt.catch
                      (fun () -> Lwt_unix_retry.unlink path)
                      (function
                        | Unix.Unix_error _ -> Lwt.return_unit
                        | exn -> Lwt.fail exn)
                  in
                  go (total - bytes) rest
            in
            go total coldest)

  (* The body if it is here, without fetching: for a repair that wants to know
     whether the local copy can stand in, not to read content. *)
  let body_if_local ~chunk_key =
    Lwt.catch
      (fun () ->
        let+ body =
          Lwt_io.with_file ~mode:Lwt_io.Input (path chunk_key) Lwt_io.read
        in
        Some body)
      (fun _ -> Lwt.return_none)

  let forget ~chunk_key =
    Lwt.catch
      (fun () -> Lwt_unix_retry.unlink (path chunk_key))
      (function Unix.Unix_error _ -> Lwt.return_unit | exn -> Lwt.fail exn)

  (* Integrity pass: a body must hash to its own name. Content addressing makes
     this the whole check — no manifest, no file, no per-chunk record is involved
     — and the repair is a deletion, since the bytes come back from the backend on
     the next read. Returns (checked, dropped). *)
  let verify () =
    let* items = Lwt.catch entries (fun _ -> Lwt.return_nil) in
    Lwt_list.fold_left_s
      (fun (checked, dropped) (path, _, _) ->
        let name = Filename.basename path in
        let* data =
          Lwt.catch
            (fun () ->
              let+ body =
                Lwt_io.with_file ~mode:Lwt_io.Input path Lwt_io.read
              in
              Some body)
            (fun _ -> Lwt.return_none)
        in
        let ok =
          match data with
            | None -> false
            | Some data ->
                Printf.sprintf "%s-%s" (Xxhash.hash_hex data 0)
                  (Xxhash.hash_hex data 1)
                = name
        in
        if ok then Lwt.return (checked + 1, dropped)
        else (
          Log.info "chunk cache: dropping corrupt %s" name;
          let+ () =
            Lwt.catch
              (fun () -> Lwt_unix_retry.unlink path)
              (function
                | Unix.Unix_error _ -> Lwt.return_unit | exn -> Lwt.fail exn)
          in
          (checked + 1, dropped + 1)))
      (0, 0) items

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

  (* A new body holding a published chunk's bytes, for a write that covers only
     part of it. This copy is the price of immutable content-addressed chunks. *)
  let stage_from_chunk ~chunk_key ~uuid =
    let* () = ensure ~chunk_key () in
    let p = staged_path uuid in
    let* () = Fs_util.ensure_parent p in
    Fs_util.copy_file ~src:(path chunk_key) ~dst:p

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

  let stage_forget ~uuid =
    Lwt.catch
      (fun () -> Lwt_unix_retry.unlink (staged_path uuid))
      (function Unix.Unix_error _ -> Lwt.return_unit | exn -> Lwt.fail exn)

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
            Lwt.catch
              (fun () -> Lwt_unix_retry.unlink src)
              (fun _ -> Lwt.return_unit)
        | exn -> Lwt.fail exn)

  let whole_read_into ~uuid buf ~offset =
    Local_io.read (whole_path uuid) buf ~offset

  let whole_forget ~uuid =
    Lwt.catch
      (fun () -> Lwt_unix_retry.unlink (whole_path uuid))
      (function Unix.Unix_error _ -> Lwt.return_unit | exn -> Lwt.fail exn)

  (* Move a staged body under the content key its bytes hash to. Idempotent: an
     interrupted promotion can be replayed, and a body whose content is already
     cached is simply dropped. *)
  let promote ~uuid ~chunk_key =
    let src = staged_path uuid in
    let* staged = Lwt_unix_retry.file_exists src in
    if not staged then Lwt.return_unit
    else (
      let dst = path chunk_key in
      let* present = Lwt_unix_retry.file_exists dst in
      if present then stage_forget ~uuid
      else
        let* () = Fs_util.ensure_parent dst in
        Lwt_unix_retry.rename src dst)

  (* Fill [buf] from [chunk_key]'s body starting [chunk_off] bytes into it,
     fetching the body if it is absent. The cap may delete a chunk between the
     fetch and the read, or even mid-read, so a miss or a short read is retried
     once against a freshly fetched body; a second failure is real and raised. *)
  let read_into ~chunk_key buf ~chunk_off =
    let want = Bigarray.Array1.dim buf in
    let attempt () =
      Local_io.read (path chunk_key) buf ~offset:(Int64.of_int chunk_off)
    in
    let refetch () =
      let* () = ensure ~force:true ~chunk_key () in
      attempt ()
    in
    let* () = ensure ~chunk_key () in
    Lwt.catch
      (fun () ->
        let* n = attempt () in
        if n = want then Lwt.return n else refetch ())
      (function
        | Unix.Unix_error (Unix.ENOENT, _, _) -> refetch ()
        | exn -> Lwt.fail exn)
end
