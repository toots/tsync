open Lwt.Syntax

exception Cancelled = Backend.Cancelled

(* Read [len] bytes at [offset] from [path] into a string; these bytes are both
   hashed and uploaded. A short read means the file was truncated under us:
   abort the upload. *)
let read_chunk_string path offset len =
  let* fd = Lwt_unix.openfile path [Unix.O_RDONLY] 0 in
  Lwt.finalize
    (fun () ->
      let buf = Bytes.create len in
      let* _ =
        Lwt_unix.LargeFile.lseek fd (Int64.of_int offset) Unix.SEEK_SET
      in
      let rec loop pos =
        if pos >= len then Lwt.return_unit
        else
          let* n = Lwt_unix.read fd buf pos (len - pos) in
          if n = 0 then raise Cancelled else loop (pos + n)
      in
      let+ () = loop 0 in
      Bytes.unsafe_to_string buf)
    (fun () -> Lwt_unix.close fd)

(* Process [xs] with at most [width] tasks running concurrently, preserving
   order. Bounds peak memory to [width] chunk buffers. *)
let map_bounded width f xs =
  let rec batches = function
    | [] -> []
    | l ->
        let head = List.filteri (fun i _ -> i < width) l in
        let tail = List.filteri (fun i _ -> i >= width) l in
        head :: batches tail
  in
  let+ groups =
    Lwt_list.map_s (fun batch -> Lwt_list.map_p f batch) (batches xs)
  in
  List.concat groups

module Make (C : Conf.S) = struct
  let primary () =
    match C.backends with
      | [] -> failwith "no backends configured"
      | b :: _ -> b

  let put_all ~key ~data () =
    Lwt_list.iter_s
      (fun (module B : Backend.S) -> B.put ~key ~data ())
      C.backends

  (* How many chunks are in flight at once for a single file. An I/O and memory
     bound: each in-flight chunk holds an 8 MB payload copy. *)
  let upload_concurrency = 4

  (* Chunk keys known to exist on the primary backend. Seeded once by listing
     the chunk prefix, then maintained as we upload. Replaces a HEAD round trip
     per chunk with a local lookup — half the requests per uploaded chunk, so
     less exposure to request-rate throttling. Chunks uploaded by other clients
     mid-session are missed and re-uploaded; chunk puts are idempotent
     (content-addressed keys), so that is only a little wasted bandwidth. *)
  let known_chunks : (string, unit) Hashtbl.t = Hashtbl.create 65536

  let seed_known_chunks () =
    let (module Primary : Backend.S) = primary () in
    let* entries = Primary.list_all ~prefix:C.chunk_prefix () in
    let plen = String.length C.chunk_prefix in
    List.iter
      (fun (e : Backend.file_entry) ->
        if String.length e.key > plen then
          Hashtbl.replace known_chunks
            (String.sub e.key plen (String.length e.key - plen))
            ())
      entries;
    Log.info "chunk index: %d chunks on backend" (Hashtbl.length known_chunks);
    Lwt.return_unit

  (* Lazily seed on first use; a listing failure is retried on the next chunk
     rather than cached forever. *)
  let known_chunks_seeded = ref None

  let ensure_known_chunks () =
    match !known_chunks_seeded with
      | Some t -> t
      | None ->
          let t =
            Lwt.catch seed_known_chunks (fun exn ->
                Log.err "chunk index listing failed: %s"
                  (Printexc.to_string exn);
                known_chunks_seeded := None;
                Lwt.return_unit)
          in
          known_chunks_seeded := Some t;
          t

  (* Read, hash and (if not already present) upload chunk [index], returning
     its manifest entry. *)
  let upload_chunk src_path ~cancel ~file_size index =
    if !cancel then raise Cancelled;
    let offset = index * Manifest.chunk_size in
    let size = min Manifest.chunk_size (file_size - offset) in
    let* data = read_chunk_string src_path offset size in
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
    let* () = ensure_known_chunks () in
    let ck_rel = Manifest.chunk_key entry in
    let ck = C.chunk_prefix ^ ck_rel in
    let+ () =
      if Hashtbl.mem known_chunks ck_rel then Lwt.return_unit
      else (
        Metrics.add_uploaded size;
        let+ () = put_all ~key:ck ~data () in
        Hashtbl.replace known_chunks ck_rel ())
    in
    entry

  let upload ~key ~src_path ~mtime ?(cancel = ref false) () =
    let* st = Lwt_unix.stat src_path in
    let file_size = st.Unix.st_size in
    Log.debug "upload %s: file_size=%d" key file_size;
    let num_chunks =
      if file_size = 0 then 1
      else (file_size + Manifest.chunk_size - 1) / Manifest.chunk_size
    in
    let* entries =
      map_bounded upload_concurrency
        (upload_chunk src_path ~cancel ~file_size)
        (List.init num_chunks Fun.id)
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
    let* () = put_all ~key ~data:(Manifest.to_string state) () in
    (* The upload may have been cancelled while the manifest put was in
       flight (e.g. the file was renamed away mid-upload). Leaving the
       manifest published would create a ghost object under a name that no
       longer exists locally; undo it. Chunks stay: they are content-addressed
       and referenced by the successor upload. *)
    if !cancel then (
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
      raise Cancelled)
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
            let* _ =
              Lwt_unix.LargeFile.lseek fd
                (Int64.of_int (chunk.index * manifest.Manifest.chunk_size))
                Unix.SEEK_SET
            in
            let len = String.length data in
            let rec loop pos =
              if pos >= len then Lwt.return_unit
              else
                let* n = Lwt_unix.write_string fd data pos (len - pos) in
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
