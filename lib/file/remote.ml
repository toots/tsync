open Lwt.Syntax

exception Cancelled = Backend.Cancelled

(* Memory-map [src_path] read-only as an off-heap bigarray, so the whole file
   can be hashed under a single runtime-lock release without committing its size
   in RAM (the OS pages it in on demand). Safe against concurrent writes: those
   rename-replace the cache file (new inode), leaving this mapping valid — the
   file is never truncated in place. An empty file yields an empty buffer. *)
let map_file_bigarray src_path file_size =
  if file_size = 0 then Lwt.return (Lwt_bytes.create 0)
  else
    let* fd = Lwt_unix.openfile src_path [Unix.O_RDONLY] 0 in
    Lwt.finalize
      (fun () ->
        let ba =
          Unix.map_file
            (Lwt_unix.unix_file_descr fd)
            Bigarray.char Bigarray.c_layout false [| file_size |]
        in
        Lwt.return (Bigarray.array1_of_genarray ba))
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

  (* How many chunks are uploaded at once for a single file. An I/O and memory
     bound (each in-flight chunk holds an 8 MB payload copy), independent of CPU
     count. Hashing is no longer per-chunk: the whole file is hashed in one pass
     (see [upload]), so this bounds only the chunk uploads. *)
  let upload_concurrency = 4

  (* Upload one chunk from the mapped file buffer if it is not already present. *)
  let upload_chunk buf ~cancel (entry : Manifest.chunk_entry) =
    if Atomic.get cancel then raise Cancelled;
    let ck = C.chunk_prefix ^ Manifest.chunk_key entry in
    let (module Primary : Backend.S) = primary () in
    let* head = Primary.head_opt ~key:ck () in
    if head <> None then Lwt.return_unit
    else (
      let offset = entry.Manifest.index * Manifest.chunk_size in
      let slice = Bigarray.Array1.sub buf offset entry.Manifest.size in
      Metrics.add_uploaded entry.Manifest.size;
      put_all ~key:ck ~data:(Lwt_bytes.to_string slice) ())

  let upload ~key ~src_path ~mtime ?(cancel = Atomic.make false) () =
    let* stat = Lwt_unix.stat src_path in
    let file_size = stat.Unix.st_size in
    Log.debug "upload %s: file_size=%d" key file_size;
    let num_chunks =
      max 1 ((file_size + Manifest.chunk_size - 1) / Manifest.chunk_size)
    in
    let* buf = map_file_bigarray src_path file_size in
    if Atomic.get cancel then raise Cancelled;
    (* One detach, one runtime-lock release, all chunks (both seeds). *)
    let* hashes =
      Hash_pool.detach
        (fun () ->
          Xxhash.hash_chunks_bigarray buf ~length:file_size
            ~chunk_size:Manifest.chunk_size)
        ()
    in
    Metrics.add_hashed num_chunks;
    if Atomic.get cancel then raise Cancelled;
    let entries =
      List.init num_chunks (fun i ->
          let h1, h2 = hashes.(i) in
          let len =
            min Manifest.chunk_size (file_size - (i * Manifest.chunk_size))
          in
          Manifest.{ index = i; h1; h2; size = len })
    in
    let* (_ : unit list) =
      map_bounded upload_concurrency (upload_chunk buf ~cancel) entries
    in
    if Atomic.get cancel then raise Cancelled;
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
    let+ () = put_all ~key ~data:(Manifest.to_string state) () in
    state

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
