open Lwt.Syntax

exception Cancelled = Backend.Cancelled

type recheck_report = {
  chunks_total : int;
  chunks_repaired : int;
  chunks_unrepairable : int;
  manifest_repaired : bool;
  manifest_bad : bool;
  local_stale : bool;
}

let manifest_matches (a : Manifest.t) (b : Manifest.t) =
  a.Manifest.h1 = b.Manifest.h1
  && a.Manifest.h2 = b.Manifest.h2
  && a.Manifest.size = b.Manifest.size

(* Read [len] bytes at [offset] from [fd] into [buf] (starting at 0). Uses
   positioned reads rather than lseek+read: chunks, including chunks of the
   same file, are read concurrently (see [chunk_buffers] and [max_uploads]),
   and a shared fd's seek position would race across concurrent readers.
   pread has no such shared state, so one fd can be opened per file instead
   of per chunk — each open, seek and close was a separate blocking syscall
   dispatched to Lwt's worker-thread pool, and for a multi-GB file split
   into hundreds of 8 MB chunks that adds up to thousands of thread-pool
   round trips per upload. A short read means the file was truncated under
   us: abort the upload. *)
let read_chunk_into fd offset len buf =
  let rec loop pos =
    if pos >= len then Lwt.return_unit
    else
      let* n =
        Lwt_unix_retry.pread fd buf ~file_offset:(offset + pos) pos (len - pos)
      in
      if n = 0 then raise Cancelled else loop (pos + n)
  in
  loop 0

module Make (C : Conf.S) = struct
  let primary () =
    match C.backends with
      | [] -> failwith "no backends configured"
      | b :: _ -> b

  (* Manifest reads/writes go through [St], which maps logical keys to backend
     keys via the layout scheme. [rel_of] is the domain-relative real path
     recorded in the manifest body. *)
  module St = Store.Make (C) (Layout.Inode.Make (C))

  let put_all ~key ~data () =
    Lwt_list.iter_s
      (fun (module B : Backend.S) -> B.put ~key ~data ())
      C.backends

  (* A bounded pool of 8 MB chunk buffers, shared by every concurrent upload.
     Reusing a fixed set avoids a constant stream of large major-heap
     allocations (significant GC overhead under sustained upload traffic);
     Lwt_pool allocates each slot lazily, so nothing is held when no upload
     is in flight. Callers must not retain the string derived from a buffer
     past the pool callback: it aliases the buffer's backing memory.

     Acquiring from this pool is also what actually bounds concurrent chunk
     work system-wide: a chunk read blocks here until a slot frees, whatever
     file it belongs to, making [max_uploads] the single, real ceiling on
     concurrent upload operations. *)
  let chunk_buffers =
    Lwt_pool.create (max 1 C.max_uploads) (fun () ->
        Lwt.return (Bytes.create Manifest.chunk_size))

  (* Chunk keys known to exist on the primary backend, for this session only.
     A HEAD check decides existence per chunk; once confirmed (either found
     or just uploaded), the result is memoized here so a chunk repeated
     within the same session — the same content in another file, or a retry
     after a crash — skips the round trip. We don't pre-populate this by
     listing the whole chunk prefix: that cost scales with the size of the
     entire historical archive rather than with the upload actually being
     done, and only pays off for cross-session or cross-file dedup, which is
     rare for largely-unique source content. *)
  let known_chunks : (string, unit) Hashtbl.t = Hashtbl.create 4096

  let chunk_exists ck =
    let (module Primary : Backend.S) = primary () in
    let+ head = Primary.head_opt ~key:ck () in
    Option.is_some head

  (* Hash the full content of [path] sequentially, feeding bytes into each
     [Xxhash.state] in [states] in order. Used to compute the manifest h1/h2
     as a true content hash rather than a hash-of-hashes. *)
  let stream_hash ~path states =
    let buf = Bytes.create Manifest.chunk_size in
    let* fd = Lwt_unix_retry.openfile path [Unix.O_RDONLY] 0 in
    Lwt.finalize
      (fun () ->
        let rec loop () =
          let* n = Lwt_unix_retry.read fd buf 0 Manifest.chunk_size in
          if n = 0 then Lwt.return_unit
          else (
            let data =
              if n = Bytes.length buf then Bytes.unsafe_to_string buf
              else Bytes.sub_string buf 0 n
            in
            List.iter (fun s -> Xxhash.update s data) states;
            loop ())
        in
        loop ())
      (fun () -> Lwt_unix_retry.close fd)

  (* Read, hash and (if not already present) upload chunk [index], returning
     its manifest entry. *)
  let upload_chunk fd ~cancel ~file_size index =
    if !cancel then raise Cancelled;
    let offset = index * Manifest.chunk_size in
    let size = min Manifest.chunk_size (file_size - offset) in
    Lwt_pool.use chunk_buffers (fun buf ->
        let* () = read_chunk_into fd offset size buf in
        (* Zero-copy in the common (full-chunk) case; the last chunk of a
           file is short and needs its own copy since it can't alias the
           whole pooled buffer. Either way, [data] must not outlive this
           chunk's use (hash + upload) since the buffer is reused once
           released below. *)
        let data =
          if size = Bytes.length buf then Bytes.unsafe_to_string buf
          else Bytes.sub_string buf 0 size
        in
        let entry =
          Manifest.
            {
              index;
              h1 = Xxhash.hash_hex data 0;
              h2 = Xxhash.hash_hex data 1;
              size;
            }
        in
        Metrics.add_hashed 1;
        let ck_rel = Manifest.chunk_key entry in
        let ck = C.chunk_prefix ^ ck_rel in
        let* known =
          if Hashtbl.mem known_chunks ck_rel then Lwt.return_true
          else chunk_exists ck
        in
        let+ () =
          if known then (
            Hashtbl.replace known_chunks ck_rel ();
            Lwt.return_unit)
          else (
            Metrics.add_uploaded size;
            let+ () = put_all ~key:ck ~data () in
            Hashtbl.replace known_chunks ck_rel ())
        in
        entry)

  let upload ~key ~src_path ~mtime ?(cancel = ref false) () =
    let* st = Lwt_unix_retry.stat src_path in
    let file_size = st.Unix.st_size in
    Log.debug "upload %s: file_size=%d" key file_size;
    let num_chunks =
      if file_size = 0 then 1
      else (file_size + Manifest.chunk_size - 1) / Manifest.chunk_size
    in
    let* fd = Lwt_unix_retry.openfile src_path [Unix.O_RDONLY] 0 in
    let* entries =
      Lwt.finalize
        (fun () ->
          (* Launching every chunk's task up front is safe even for files
             with thousands of chunks: each one immediately blocks on the
             [chunk_buffers] pool until a slot is free, so real concurrency
             stays capped at [max_uploads] regardless of how many chunks (or
             how many other files' chunks) are contending for one. *)
          Lwt_list.map_p
            (upload_chunk fd ~cancel ~file_size)
            (List.init num_chunks Fun.id))
        (fun () -> Lwt_unix_retry.close fd)
    in
    if !cancel then raise Cancelled;
    let s1 = Xxhash.create 0 and s2 = Xxhash.create 1 in
    let* () = stream_hash ~path:src_path [s1; s2] in
    let state =
      Manifest.make ~name:(Filename.basename key) ~h1:(Xxhash.digest_hex s1)
        ~h2:(Xxhash.digest_hex s2) ~size:(Int64.of_int file_size)
        ~chunk_size:Manifest.chunk_size ~chunks:entries ~mtime
    in
    let* () = if C.versioning then St.save_version ~key else Lwt.return_unit in
    Log.info "upload %s: publishing manifest, size=%d" key file_size;
    let* () = St.put_manifest ~key ~data:(Manifest.to_string state) in
    (* The upload may have been cancelled while the manifest put was in
       flight (e.g. the file was renamed away mid-upload). Leaving the
       manifest published would create a ghost object under a name that no
       longer exists locally; undo it. Chunks stay: they are content-addressed
       and referenced by the successor upload. *)
    if !cancel then
      let* () =
        Lwt.catch
          (fun () -> St.delete_manifest ~key)
          (fun exn ->
            Log.err "upload %s: cancelled-manifest cleanup failed: %s" key
              (Printexc.to_string exn);
            Lwt.return_unit)
      in
      raise Cancelled
    else Lwt.return state

  let fetch_manifest ~key () =
    let+ body = St.get_manifest_opt ~key in
    match body with
      | None -> None
      | Some body -> (
          (* A manifest that fails to parse is treated as absent: stat/getattr
             report ENOENT rather than surfacing garbage metadata. *)
            match Manifest.of_string body with
            | `Dirty -> None
            | `Clean _ as state -> Some state
            | exception _ -> None)

  (* ── Recheck: verify remote state against local data / sidecar ─────────── *)

  (* A chunk is correct remotely when it exists on the primary backend and its
     size matches: chunk keys are content-addressed, so a size mismatch means
     the remote object is corrupt. *)
  let chunk_remote_ok (entry : Manifest.chunk_entry) =
    let (module Primary : Backend.S) = primary () in
    let+ head =
      Primary.head_opt ~key:(C.chunk_prefix ^ Manifest.chunk_key entry) ()
    in
    match head with
      | Some h -> h.Backend.size = entry.Manifest.size
      | None -> false

  (* Read and hash chunk [index] of the local file, verify it remotely, and
     re-upload it (put overwrites, also fixing a corrupt object) when wrong.
     Returns the manifest entry and whether a repair was made. *)
  let recheck_chunk fd ~file_size index =
    let offset = index * Manifest.chunk_size in
    let size = min Manifest.chunk_size (file_size - offset) in
    Lwt_pool.use chunk_buffers (fun buf ->
        let* () = read_chunk_into fd offset size buf in
        let data =
          if size = Bytes.length buf then Bytes.unsafe_to_string buf
          else Bytes.sub_string buf 0 size
        in
        let entry =
          Manifest.
            {
              index;
              h1 = Xxhash.hash_hex data 0;
              h2 = Xxhash.hash_hex data 1;
              size;
            }
        in
        let* ok = chunk_remote_ok entry in
        let+ () =
          if ok then Lwt.return_unit
          else (
            Log.info "recheck: re-uploading chunk %s" (Manifest.chunk_key entry);
            put_all ~key:(C.chunk_prefix ^ Manifest.chunk_key entry) ~data ())
        in
        (entry, not ok))

  (* Fetch the remote manifest for [key] and republish [expected] when it is
     missing, dirty or differs. Returns [true] when a repair was made. *)
  let recheck_manifest ~key (expected : Manifest.t) =
    let* remote = fetch_manifest ~key () in
    let ok =
      match remote with
        | Some (`Clean r) -> manifest_matches r expected
        | _ -> false
    in
    if ok then Lwt.return_false
    else (
      Log.info "recheck: republishing manifest %s" key;
      let+ () =
        St.put_manifest ~key ~data:(Manifest.to_string (`Clean expected))
      in
      true)

  (* Recheck a file whose data is in the local cache: re-hash it chunk by
     chunk, verify/repair each chunk remotely, then verify/repair the remote
     manifest. Returns the freshly computed manifest state (the caller
     refreshes the sidecar) and a report; [local_stale] is set when the
     re-hash disagrees with [sidecar]. *)
  let recheck_cached ~key ~src_path ~mtime ~sidecar () =
    let* st = Lwt_unix_retry.stat src_path in
    let file_size = st.Unix.st_size in
    let num_chunks =
      if file_size = 0 then 1
      else (file_size + Manifest.chunk_size - 1) / Manifest.chunk_size
    in
    let* fd = Lwt_unix_retry.openfile src_path [Unix.O_RDONLY] 0 in
    let* results =
      Lwt.finalize
        (fun () ->
          Lwt_list.map_p
            (recheck_chunk fd ~file_size)
            (List.init num_chunks Fun.id))
        (fun () -> Lwt_unix_retry.close fd)
    in
    let entries = List.map fst results in
    let s1 = Xxhash.create 0 and s2 = Xxhash.create 1 in
    let* () = stream_hash ~path:src_path [s1; s2] in
    let state =
      Manifest.make ~name:(Filename.basename key) ~h1:(Xxhash.digest_hex s1)
        ~h2:(Xxhash.digest_hex s2) ~size:(Int64.of_int file_size)
        ~chunk_size:Manifest.chunk_size ~chunks:entries ~mtime
    in
    let expected = match state with `Clean m -> m | `Dirty -> assert false in
    let+ manifest_repaired = recheck_manifest ~key expected in
    ( state,
      {
        chunks_total = num_chunks;
        chunks_repaired = List.length (List.filter snd results);
        chunks_unrepairable = 0;
        manifest_repaired;
        manifest_bad = false;
        local_stale = not (manifest_matches sidecar expected);
      } )

  (* Bounds concurrent HEADs for evicted-file rechecks, where no buffer slot
     is held to do it. *)
  let recheck_head_pool =
    Lwt_pool.create (max 1 C.max_uploads) (fun () -> Lwt.return_unit)

  (* Recheck an evicted file from its sidecar manifest alone: chunks cannot
     be repaired without local data, but a missing/bad remote manifest is
     republished from the sidecar as long as every chunk checks out. *)
  let recheck_evicted ~key (m : Manifest.t) =
    let* oks =
      Lwt_list.map_p
        (fun entry ->
          Lwt_pool.use recheck_head_pool (fun () -> chunk_remote_ok entry))
        m.Manifest.chunks
    in
    let chunks_unrepairable =
      List.length (List.filter (fun ok -> not ok) oks)
    in
    let+ manifest_repaired, manifest_bad =
      if chunks_unrepairable > 0 then
        let* remote = fetch_manifest ~key () in
        let ok =
          match remote with
            | Some (`Clean r) -> manifest_matches r m
            | _ -> false
        in
        Lwt.return (false, not ok)
      else
        let+ repaired = recheck_manifest ~key m in
        (repaired, false)
    in
    {
      chunks_total = List.length m.Manifest.chunks;
      chunks_repaired = 0;
      chunks_unrepairable;
      manifest_repaired;
      manifest_bad;
      local_stale = false;
    }

  (* Bounds concurrent chunk GETs across all downloads, mirroring how
     [chunk_buffers] bounds upload work: every chunk of every file contends
     for the same [max_downloads] slots, so launching all of a file's chunk
     tasks up front cannot exceed the global ceiling. *)
  let chunk_download_pool =
    Lwt_pool.create (max 1 C.max_downloads) (fun () -> Lwt.return_unit)

  (* Per-key (bytes_done, total_bytes) for in-flight downloads; used by the
     FileProvider extension to display a progress bar. Absent when no download
     is active for that key. *)
  let active_downloads : (string, int * int) Hashtbl.t = Hashtbl.create 8
  let get_download_progress key = Hashtbl.find_opt active_downloads key

  let assemble_chunks ~key ~(manifest : Manifest.t) ~dst_path primary =
    let total = Int64.to_int manifest.Manifest.size in
    Hashtbl.replace active_downloads key (0, total);
    let (module Primary : Backend.S) = primary in
    let* fd =
      Lwt_unix_retry.openfile dst_path
        [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC]
        0o644
    in
    Lwt.finalize
      (fun () ->
        let* () =
          Lwt_unix_retry.LargeFile.ftruncate fd manifest.Manifest.size
        in
        Lwt_list.iter_p
          (fun (chunk : Manifest.chunk_entry) ->
            Lwt_pool.use chunk_download_pool (fun () ->
                let ck = C.chunk_prefix ^ Manifest.chunk_key chunk in
                let* data = Primary.get ~key:ck () in
                let n = String.length data in
                Metrics.add_downloaded n;
                (match Hashtbl.find_opt active_downloads key with
                  | Some (done_, total) ->
                      Hashtbl.replace active_downloads key (done_ + n, total)
                  | None -> ());
                (* pwrite: positioned writes have no shared fd offset, so
                   concurrent chunk writes to the same fd are safe. *)
                let base = chunk.index * manifest.Manifest.chunk_size in
                let len = n in
                let rec loop pos =
                  if pos >= len then Lwt.return_unit
                  else
                    let* n =
                      Lwt_unix_retry.pwrite_string fd data
                        ~file_offset:(base + pos) pos (len - pos)
                    in
                    loop (pos + n)
                in
                loop 0))
          manifest.Manifest.chunks)
      (fun () ->
        Hashtbl.remove active_downloads key;
        Lwt_unix_retry.close fd)

  let download_chunks ~key ~dst_path manifest =
    assemble_chunks ~key ~manifest ~dst_path (primary ())

  let download ~key ~dst_path =
    let (module Primary : Backend.S) = primary () in
    let* body = St.get_manifest_opt ~key in
    match body with
      | None -> Lwt.fail (Backend.Backend_error ("not found: " ^ key))
      | Some body -> (
          match Manifest.of_string body with
            | `Dirty -> Lwt.return_none
            | `Clean manifest as state ->
                let+ () =
                  assemble_chunks ~key ~manifest ~dst_path (module Primary)
                in
                Some state)
end
