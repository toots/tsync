open Lwt.Syntax

exception Cancelled = Backend.Cancelled

(* Read [len] bytes at [offset] from [path] into a string, for uploading a chunk.
   Hashing reads the file itself (in C, via the hash state); this is the separate
   read of the bytes to send. *)
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
          if n = 0 then Lwt.return_unit else loop (pos + n)
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

  (* How many chunks are uploaded at once for a single file. An I/O and memory
     bound (each in-flight chunk holds an 8 MB payload copy), independent of CPU
     count and of hashing (the whole file is hashed in one pass in [upload]). *)
  let upload_concurrency = 4

  (* Upload one chunk (read from [src_path]) if it is not already present. *)
  let upload_chunk src_path ~cancel (entry : Manifest.chunk_entry) =
    if Xxhash.hash_state_is_cancelled cancel then raise Cancelled;
    let ck = C.chunk_prefix ^ Manifest.chunk_key entry in
    let (module Primary : Backend.S) = primary () in
    let* head = Primary.head_opt ~key:ck () in
    if head <> None then Lwt.return_unit
    else (
      let offset = entry.Manifest.index * Manifest.chunk_size in
      let* data = read_chunk_string src_path offset entry.Manifest.size in
      Metrics.add_uploaded entry.Manifest.size;
      put_all ~key:ck ~data ())

  let upload ~key ~src_path ~mtime ?cancel () =
    let cancel =
      match cancel with
        | Some c -> c
        | None -> Xxhash.hash_state_create src_path
    in
    (* C opens, mmaps and hashes the whole file, polling [cancel] between chunks
       and releasing the runtime lock for the loop. [None] = cancelled mid-hash
       (or the file vanished). *)
    let* hashes =
      Hash_pool.detach
        (fun () ->
          Xxhash.hash_file_chunks cancel ~chunk_size:Manifest.chunk_size)
        ()
    in
    match hashes with
      | None -> raise Cancelled
      | Some (file_size, hashes) ->
          let num_chunks = Array.length hashes in
          Log.debug "upload %s: file_size=%d" key file_size;
          Metrics.add_hashed num_chunks;
          let entries =
            List.init num_chunks (fun i ->
                let h1, h2 = hashes.(i) in
                let len =
                  min Manifest.chunk_size (file_size - (i * Manifest.chunk_size))
                in
                Manifest.{ index = i; h1; h2; size = len })
          in
          let* (_ : unit list) =
            map_bounded upload_concurrency
              (upload_chunk src_path ~cancel)
              entries
          in
          if Xxhash.hash_state_is_cancelled cancel then raise Cancelled;
          let state =
            Manifest.make ~size:(Int64.of_int file_size)
              ~chunk_size:Manifest.chunk_size ~chunks:entries ~mtime
          in
          let* () =
            if C.versioning then
              Versioning.save ~backends:C.backends
                ~domain_prefix:C.domain_prefix
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
