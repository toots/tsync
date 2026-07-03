open Lwt.Syntax

exception Cancelled = Backend.Cancelled

(* Read [len] bytes at [offset] from [path] into a fresh off-heap buffer, safe to
   hash with the runtime lock released. *)
let read_chunk_bigarray path offset len =
  let buf = Lwt_bytes.create len in
  let* fd = Lwt_unix.openfile path [Unix.O_RDONLY] 0 in
  Lwt.finalize
    (fun () ->
      let* _ =
        Lwt_unix.LargeFile.lseek fd (Int64.of_int offset) Unix.SEEK_SET
      in
      let rec loop pos =
        if pos >= len then Lwt.return_unit
        else
          let* n = Lwt_bytes.read fd buf pos (len - pos) in
          if n = 0 then Lwt.return_unit else loop (pos + n)
      in
      let+ () = loop 0 in
      buf)
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

  let hash_width = max 1 (Domain.recommended_domain_count () - 1)

  (* Read, hash (in parallel on the domain pool) and upload one chunk if it is
     not already present. Returns its manifest entry. *)
  let process_chunk src_path ~cancel (index, offset, len) =
    if Atomic.get cancel then raise Cancelled;
    let* buf = read_chunk_bigarray src_path offset len in
    let* h1, h2 =
      Hash_pool.detach
        (fun () ->
          ( Xxhash.hash_hex_bigarray buf ~length:len 0,
            Xxhash.hash_hex_bigarray buf ~length:len 1 ))
        ()
    in
    let entry = Manifest.{ index; h1; h2; size = len } in
    let ck = C.chunk_prefix ^ Manifest.chunk_key entry in
    let (module Primary : Backend.S) = primary () in
    let* head = Primary.head_opt ~key:ck () in
    let+ () =
      if head = None then put_all ~key:ck ~data:(Lwt_bytes.to_string buf) ()
      else Lwt.return_unit
    in
    entry

  let upload ~key ~src_path ~mtime ?(cancel = Atomic.make false) () =
    let* stat = Lwt_unix.stat src_path in
    let file_size = stat.Unix.st_size in
    Log.debug "upload %s: file_size=%d" key file_size;
    let num_chunks =
      max 1 ((file_size + Manifest.chunk_size - 1) / Manifest.chunk_size)
    in
    let chunks =
      List.init num_chunks (fun i ->
          let offset = i * Manifest.chunk_size in
          let len = min Manifest.chunk_size (file_size - offset) in
          (i, offset, len))
    in
    let* entries =
      map_bounded hash_width (process_chunk src_path ~cancel) chunks
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
