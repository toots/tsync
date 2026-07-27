open Lwt.Syntax

exception Cancelled = Backend.Cancelled

type recheck_report = {
  chunks_total : int;
  chunks_repaired : int;
  chunks_unrepairable : int;
  manifest_repaired : bool;
  manifest_bad : bool;
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

module type S = sig
  val upload :
    key:string ->
    src_path:string ->
    mtime:float ->
    chunk_size:int ->
    ?cancel:bool ref ->
    unit ->
    Manifest.state Lwt.t

  val get_chunk : chunk_key:string -> string Lwt.t

  (** Chunk size for files this client creates; see the .mli. *)
  val chunk_size : unit -> int Lwt.t

  val upload_chunks :
    key:string ->
    name:string ->
    size:int64 ->
    chunk_size:int ->
    mtime:float ->
    source:(int -> [ `Reuse of Manifest.chunk_entry | `Data of string ] Lwt.t) ->
    ?cancel:bool ref ->
    unit ->
    Manifest.state Lwt.t

  val fetch_manifest : key:string -> unit -> Manifest.state option Lwt.t

  val recheck_from_manifest :
    key:string ->
    local_body:(Manifest.chunk_entry -> string option Lwt.t) ->
    Manifest.t ->
    recheck_report Lwt.t
end

module Make_with_layout (C : Conf.S) (L : Layout.S) : S = struct
  let primary () =
    match C.backends with
      | [] -> failwith "no backends configured"
      | b :: _ -> b

  (* Manifest reads/writes go through [St], which maps logical keys to backend
     keys via the layout scheme. [rel_of] is the domain-relative real path
     recorded in the manifest body. *)
  module St = Store.Make (C) (L)

  let put_all ~key ~data () =
    Lwt_list.iter_s
      (fun (module B : Backend.S) -> B.put ~key ~data ())
      C.backends

  (* A bounded pool of chunk-sized buffers (this domain's configured chunk
     size), shared by every concurrent upload. Reusing a fixed set avoids a
     constant stream of large major-heap allocations (significant GC overhead
     under sustained upload traffic); Lwt_pool allocates each slot lazily, so
     nothing is held when no upload is in flight. Callers must not retain the
     string derived from a buffer past the pool callback: it aliases the
     buffer's backing memory.

     Acquiring from this pool is also what actually bounds concurrent chunk
     work system-wide: a chunk read blocks here until a slot frees, whatever
     file it belongs to, making [max_uploads] the single, real ceiling on
     concurrent upload operations. *)
  (* The pool sizes buffers off the configured value, not the resolved one: it
     only needs an upper bound that fits the common case, and an oversized chunk
     already falls through to a one-off allocation below. *)
  let buffer_size = Option.value C.chunk_size ~default:Conf.default_chunk_size

  let chunk_buffers =
    Lwt_pool.create (max 1 C.max_uploads) (fun () ->
        Lwt.return (Bytes.create buffer_size))

  (* Chunk size for files this client creates: what the config says, else what
     the primary backend recommends (an http-proxy answers with the serving
     domain's own, so the setting need not live in two configs), else the
     built-in default. Asked once and memoized — the answer is fixed for the life
     of the process, and every caller is on the creation path. *)
  let resolved_chunk_size = ref None

  let chunk_size () =
    match !resolved_chunk_size with
      | Some p -> p
      | None ->
          let p =
            match C.chunk_size with
              | Some n -> Lwt.return n
              | None ->
                  Lwt.catch
                    (fun () ->
                      let (module Primary : Backend.S) = primary () in
                      let+ n =
                        Primary.default_chunk_size ~prefix:C.domain_prefix ()
                      in
                      Option.value n ~default:Conf.default_chunk_size)
                    (fun _ -> Lwt.return Conf.default_chunk_size)
          in
          resolved_chunk_size := Some p;
          p

  (* Read a chunk of [size] bytes into a buffer: from the pool when it fits the
     domain chunk size, else a one-off allocation. The oversized case is only
     hit re-chunking a pre-existing file whose manifest used a larger chunk size
     than the domain now configures. *)
  let with_chunk_buffer ~size f =
    if size <= buffer_size then Lwt_pool.use chunk_buffers f
    else f (Bytes.create size)

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

  (* Hash [data] as chunk [index] and upload it unless the backend already has
     that content. [data] is not retained past this call, so a caller may pass a
     string aliasing a pooled buffer. *)
  let put_chunk ~index ~data =
    let size = String.length data in
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
    entry

  (* Read, hash and (if not already present) upload chunk [index], returning its
     manifest entry. *)
  let upload_chunk fd ~cancel ~file_size ~chunk_size index =
    if !cancel then raise Cancelled;
    let offset = index * chunk_size in
    let size = min chunk_size (file_size - offset) in
    with_chunk_buffer ~size (fun buf ->
        let* () = read_chunk_into fd offset size buf in
        (* Zero-copy in the common (full-chunk) case; the last chunk of a file is
           short and needs its own copy since it can't alias the whole pooled
           buffer. Either way, [data] must not outlive this chunk's use (hash +
           upload) since the buffer is reused once released below. *)
        let data =
          if size = Bytes.length buf then Bytes.unsafe_to_string buf
          else Bytes.sub_string buf 0 size
        in
        put_chunk ~index ~data)

  (* Whole-file upload: every chunk is read, hashed and sent unless the backend
     already holds that content. For a file handed over as one file — import, and
     the FileProvider's whole-file re-import. *)
  let upload ~key ~src_path ~mtime ~chunk_size ?(cancel = ref false) () =
    let* st = Lwt_unix_retry.stat src_path in
    let file_size = st.Unix.st_size in
    Log.debug "upload %s: file_size=%d" key file_size;
    let num_chunks =
      if file_size = 0 then 1 else (file_size + chunk_size - 1) / chunk_size
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
            (upload_chunk fd ~cancel ~file_size ~chunk_size)
            (List.init num_chunks Fun.id))
        (fun () -> Lwt_unix_retry.close fd)
    in
    if !cancel then raise Cancelled;
    let h1, h2 = Manifest.digest_of_chunks entries in
    let state =
      Manifest.make ~name:(Filename.basename key) ~h1 ~h2
        ~size:(Int64.of_int file_size) ~chunk_size ~chunks:entries ~mtime
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

  (* Publish [entries] as [key]'s manifest: the tail every upload shares. A
     cancellation that lands while the put is in flight unpublishes it again —
     leaving it would create a ghost object under a name that may no longer
     exist locally. Chunks stay: they are content-addressed and the successor
     upload references them. *)
  let publish ~key ~name ~size ~chunk_size ~mtime ~cancel entries =
    if !cancel then raise Cancelled;
    let h1, h2 = Manifest.digest_of_chunks entries in
    let state =
      Manifest.make ~name ~h1 ~h2 ~size ~chunk_size ~chunks:entries ~mtime
    in
    let* () = if C.versioning then St.save_version ~key else Lwt.return_unit in
    Log.info "upload %s: publishing manifest, size=%Ld" key size;
    let* () = St.put_manifest ~key ~data:(Manifest.to_string state) in
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

  (* Upload a file whose bytes the caller supplies per chunk: [source index] is
     either an entry to keep as-is (an unchanged chunk, never read or sent) or the
     chunk's bytes. Knowing nothing about where those bytes live keeps staging out
     of this module. An empty file still gets one (empty) chunk, so every manifest
     has at least one. *)
  let upload_chunks ~key ~name ~size ~chunk_size ~mtime ~source
      ?(cancel = ref false) () =
    let n = max 1 (Manifest.num_chunks_for size chunk_size) in
    let one index =
      if !cancel then raise Cancelled;
      let* src = source index in
      match src with
        | `Reuse entry -> Lwt.return { entry with Manifest.index }
        | `Data data -> put_chunk ~index ~data
    in
    let* entries = Lwt_list.map_p one (List.init n Fun.id) in
    publish ~key ~name ~size ~chunk_size ~mtime ~cancel entries

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

  (* Bounds concurrent HEADs for manifest-driven rechecks. *)
  let recheck_head_pool =
    Lwt_pool.create (max 1 C.max_uploads) (fun () -> Lwt.return_unit)

  (* Recheck a file from its manifest: every chunk it names must exist remotely
     with the right size, and a missing or wrong remote manifest is republished
     from the sidecar as long as they all do. Local bytes play no part — verifying
     those is {!Chunk_cache.verify}'s job. *)
  let recheck_from_manifest ~key ~local_body (m : Manifest.t) =
    (* A chunk missing or corrupt on the backend can still be restored from the
       local chunk store: content addressing means a body found under that key is
       the right bytes by construction. *)
    let check entry =
      let* ok =
        Lwt_pool.use recheck_head_pool (fun () -> chunk_remote_ok entry)
      in
      if ok then Lwt.return `Ok
      else
        let* body = local_body entry in
        match body with
          | None -> Lwt.return `Missing
          | Some data ->
              Log.info "recheck: re-uploading chunk %s"
                (Manifest.chunk_key entry);
              let+ () =
                put_all
                  ~key:(C.chunk_prefix ^ Manifest.chunk_key entry)
                  ~data ()
              in
              `Repaired
    in
    let* results = Lwt_list.map_p check m.Manifest.chunks in
    let count what = List.length (List.filter (fun r -> r = what) results) in
    let chunks_unrepairable = count `Missing in
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
      chunks_repaired = count `Repaired;
      chunks_unrepairable;
      manifest_repaired;
      manifest_bad;
    }

  (* Bounds concurrent chunk GETs across all downloads, mirroring how
     [chunk_buffers] bounds upload work: every chunk of every file contends
     for the same [max_downloads] slots, so launching all of a file's chunk
     tasks up front cannot exceed the global ceiling. *)
  let chunk_download_pool =
    Lwt_pool.create (max 1 C.max_downloads) (fun () -> Lwt.return_unit)

  (* Fetch one chunk body by content key. The pool bounds concurrent GETs the
     same way for a demand-paged read as for a whole-file download. *)
  let get_chunk ~chunk_key =
    Lwt_pool.use chunk_download_pool (fun () ->
        let (module Primary : Backend.S) = primary () in
        let+ data = Primary.get ~key:(C.chunk_prefix ^ chunk_key) () in
        Metrics.add_downloaded (String.length data);
        data)
end

(* The inode layout is what every path-keyed caller wants. *)
module Make (C : Conf.S) = Make_with_layout (C) (Layout.Inode.Make (C))
