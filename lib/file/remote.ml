open Lwt.Syntax

exception Cancelled = Backend.Cancelled

(* Read [len] bytes at [offset] from [fd] into [buf] (starting at 0). Uses
   positioned reads rather than lseek+read: chunks, including chunks of the
   same file, are read concurrently (see [Buffer_pool] and [max_uploads]),
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
        Lwt_unix.pread fd buf ~file_offset:(offset + pos) pos (len - pos)
      in
      if n = 0 then raise Cancelled else loop (pos + n)
  in
  loop 0

(* A small pool of fixed-size buffers reused across chunk reads, shared by
   every concurrent upload — not one pool per file. Chunks are 8 MB:
   allocating one fresh per read puts a constant stream of large blocks
   straight on the OCaml major heap, which under sustained upload traffic
   shows up as significant GC (mark/sweep) and runtime allocation-tracking
   overhead. Reusing a bounded set of buffers turns that into a one-time
   allocation per slot. Buffers are allocated lazily on first use of each
   slot, not up front: most of the time no upload is in flight at all, and
   we don't want [count] * chunk_size held idle for that case. Callers must
   not retain the string handed back after releasing the buffer: it aliases
   the buffer's backing memory.

   Acquiring from this pool is also what actually bounds concurrent chunk
   work system-wide: a chunk read blocks here until a slot frees, regardless
   of which file, or how many files, are contending for one. Sizing the pool
   to [max_uploads] makes that config value the single, real ceiling on
   total concurrent upload operations, rather than a per-file worker count
   with its own separate, hidden multiplier. *)
module Buffer_pool = struct
  type t = {
    size : int;
    buffers : Bytes.t option array;
    mutable free : int list;
    mutex : Lwt_mutex.t;
    not_empty : unit Lwt_condition.t;
  }

  let create ~count ~size =
    {
      size;
      buffers = Array.make count None;
      free = List.init count Fun.id;
      mutex = Lwt_mutex.create ();
      not_empty = Lwt_condition.create ();
    }

  let acquire t =
    Lwt_mutex.with_lock t.mutex (fun () ->
        let rec wait () =
          match t.free with
            | i :: rest ->
                t.free <- rest;
                let buf =
                  match t.buffers.(i) with
                    | Some buf -> buf
                    | None ->
                        let buf = Bytes.create t.size in
                        t.buffers.(i) <- Some buf;
                        buf
                in
                Lwt.return (i, buf)
            | [] ->
                let* () = Lwt_condition.wait ~mutex:t.mutex t.not_empty in
                wait ()
        in
        wait ())

  let release t i =
    Lwt_mutex.with_lock t.mutex (fun () ->
        t.free <- i :: t.free;
        Lwt_condition.signal t.not_empty ();
        Lwt.return_unit)
end

module Make (C : Conf.S) = struct
  let primary () =
    match C.backends with
      | [] -> failwith "no backends configured"
      | b :: _ -> b

  let put_all ~key ~data () =
    Lwt_list.iter_s
      (fun (module B : Backend.S) -> B.put ~key ~data ())
      C.backends

  (* Sized to [max_uploads]: see the [Buffer_pool] module comment for why
     that's what bounds real concurrent upload work. *)
  let chunk_buffers =
    Buffer_pool.create ~count:C.max_uploads ~size:Manifest.chunk_size

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

  (* Read, hash and (if not already present) upload chunk [index], returning
     its manifest entry. *)
  let upload_chunk fd ~cancel ~file_size index =
    if !cancel then raise Cancelled;
    let offset = index * Manifest.chunk_size in
    let size = min Manifest.chunk_size (file_size - offset) in
    let* slot, buf = Buffer_pool.acquire chunk_buffers in
    Lwt.finalize
      (fun () ->
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
      (fun () -> Buffer_pool.release chunk_buffers slot)

  let upload ~key ~src_path ~mtime ?(cancel = ref false) () =
    let* st = Lwt_unix.stat src_path in
    let file_size = st.Unix.st_size in
    Log.debug "upload %s: file_size=%d" key file_size;
    let num_chunks =
      if file_size = 0 then 1
      else (file_size + Manifest.chunk_size - 1) / Manifest.chunk_size
    in
    let* fd = Lwt_unix.openfile src_path [Unix.O_RDONLY] 0 in
    let* entries =
      Lwt.finalize
        (fun () ->
          (* Launching every chunk's task up front is safe even for files
             with thousands of chunks: each one immediately blocks on
             [Buffer_pool.acquire] until a slot is free, so real concurrency
             stays capped at [max_uploads] regardless of how many chunks (or
             how many other files' chunks) are contending for one. *)
          Lwt_list.map_p
            (upload_chunk fd ~cancel ~file_size)
            (List.init num_chunks Fun.id))
        (fun () -> Lwt_unix.close fd)
    in
    if !cancel then raise Cancelled;
    let state =
      Manifest.make ~size:(Int64.of_int file_size)
        ~chunk_size:Manifest.chunk_size ~chunks:entries ~mtime
    in
    let* () =
      if C.versioning then
        Versioning.save ~backends:C.backends ~domain_prefix:C.domain_prefix
          ~versions_prefix:C.versions_prefix ~key
      else Lwt.return_unit
    in
    Log.info "upload %s: publishing manifest, size=%d" key file_size;
    let* () = put_all ~key ~data:(Manifest.to_string state) () in
    (* The upload may have been cancelled while the manifest put was in
       flight (e.g. the file was renamed away mid-upload). Leaving the
       manifest published would create a ghost object under a name that no
       longer exists locally; undo it. Chunks stay: they are content-addressed
       and referenced by the successor upload. *)
    if !cancel then
      let* () =
        Lwt.catch
          (fun () ->
            Lwt_list.iter_s
              (fun (module B : Backend.S) -> B.delete ~key ())
              C.backends)
          (fun exn ->
            Log.err "upload %s: cancelled-manifest cleanup failed: %s" key
              (Printexc.to_string exn);
            Lwt.return_unit)
      in
      raise Cancelled
    else Lwt.return state

  let assemble_chunks ~(manifest : Manifest.t) ~dst_path primary =
    let (module Primary : Backend.S) = primary in
    let* fd =
      Lwt_unix.openfile dst_path
        [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC]
        0o644
    in
    Lwt.finalize
      (fun () ->
        let* () = Lwt_unix.LargeFile.ftruncate fd manifest.Manifest.size in
        Lwt_list.iter_s
          (fun (chunk : Manifest.chunk_entry) ->
            let ck = C.chunk_prefix ^ Manifest.chunk_key chunk in
            let* data = Primary.get ~key:ck () in
            Metrics.add_downloaded (String.length data);
            (* pwrite instead of lseek+write: one syscall instead of two, and
               (unlike lseek, which moves the fd's shared file position) safe
               if this is ever parallelized across chunks later. *)
            let base = chunk.index * manifest.Manifest.chunk_size in
            let len = String.length data in
            let rec loop pos =
              if pos >= len then Lwt.return_unit
              else
                let* n =
                  Lwt_unix.pwrite_string fd data ~file_offset:(base + pos) pos
                    (len - pos)
                in
                loop (pos + n)
            in
            loop 0)
          manifest.Manifest.chunks)
      (fun () -> Lwt_unix.close fd)

  let download_chunks ~dst_path manifest =
    assemble_chunks ~manifest ~dst_path (primary ())

  let fetch_manifest ~key () =
    let (module Primary : Backend.S) = primary () in
    let* head = Primary.head_opt ~key () in
    match head with
      | None -> Lwt.return_none
      | Some _ ->
          Lwt.catch
            (fun () ->
              let+ body = Primary.get ~key () in
              match Manifest.of_string body with
                | `Dirty -> None
                | `Clean _ as state -> Some state)
            (fun _ -> Lwt.return_none)

  let download ~key ~dst_path =
    let (module Primary : Backend.S) = primary () in
    let* head = Primary.head_opt ~key () in
    match head with
      | None -> Lwt.fail (Backend.Backend_error ("not found: " ^ key))
      | Some _ -> (
          let* body = Primary.get ~key () in
          match Manifest.of_string body with
            | `Dirty -> Lwt.return_none
            | `Clean manifest as state ->
                let+ () =
                  assemble_chunks ~manifest ~dst_path (module Primary)
                in
                Some state)
end
