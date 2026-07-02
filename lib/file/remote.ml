exception Cancelled = Backend.Cancelled

let read_chunk path offset len =
  let fd = Unix.openfile path [Unix.O_RDONLY] 0 in
  let buf = Bytes.create len in
  try
    ignore (Unix.lseek fd offset Unix.SEEK_SET);
    let n = Unix.read fd buf 0 len in
    Unix.close fd;
    Bytes.sub_string buf 0 n
  with exn ->
    Unix.close fd;
    raise exn

module Make (C : Conf.S) = struct
  let primary () =
    match C.backends with
      | [] -> failwith "no backends configured"
      | b :: _ -> b

  let put_all ~key ~data () =
    List.iter (fun (module B : Backend.S) -> B.put ~key ~data ()) C.backends

  let upload ~key ~src_path ~mtime ?(cancel = Atomic.make false) () =
    let stat = Unix.stat src_path in
    let file_size = stat.Unix.st_size in
    Log.debug "upload %s: file_size=%d" key file_size;
    let num_chunks =
      max 1 ((file_size + Manifest.chunk_size - 1) / Manifest.chunk_size)
    in
    let entries =
      List.init num_chunks (fun i ->
          let offset = i * Manifest.chunk_size in
          let len = min Manifest.chunk_size (file_size - offset) in
          let data = read_chunk src_path offset len in
          Manifest.
            {
              index = i;
              h1 = Xxhash.hash_hex data 0;
              h2 = Xxhash.hash_hex data 1;
              size = len;
            })
    in
    let (module Primary : Backend.S) = primary () in
    List.iter
      (fun (e : Manifest.chunk_entry) ->
        if Atomic.get cancel then raise Cancelled;
        let ck = C.chunk_prefix ^ Manifest.chunk_key e in
        if Primary.head_opt ~key:ck () = None then begin
          let data =
            read_chunk src_path (e.index * Manifest.chunk_size) e.size
          in
          put_all ~key:ck ~data ()
        end)
      entries;
    if Atomic.get cancel then raise Cancelled;
    let state =
      Manifest.make ~size:(Int64.of_int file_size)
        ~chunk_size:Manifest.chunk_size ~chunks:entries ~mtime
    in
    put_all ~key ~data:(Manifest.to_string state) ();
    state

  let assemble_chunks ~(manifest : Manifest.t) ~dst_path primary =
    let (module Primary : Backend.S) = primary in
    let fd =
      Unix.openfile dst_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644
    in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        Unix.ftruncate fd (Int64.to_int manifest.Manifest.size);
        List.iter
          (fun (chunk : Manifest.chunk_entry) ->
            let ck = C.chunk_prefix ^ Manifest.chunk_key chunk in
            let data = Primary.get ~key:ck () in
            ignore
              (Unix.lseek fd
                 (chunk.index * manifest.Manifest.chunk_size)
                 Unix.SEEK_SET);
            let written = ref 0 and len = String.length data in
            while !written < len do
              written :=
                !written + Unix.write_substring fd data !written (len - !written)
            done)
          manifest.Manifest.chunks)

  let download_chunks ~dst_path manifest =
    assemble_chunks ~manifest ~dst_path (primary ())

  let fetch_manifest ~key () =
    let (module Primary : Backend.S) = primary () in
    match Primary.head_opt ~key () with
      | None -> None
      | Some _ -> (
          try
            match Manifest.of_string (Primary.get ~key ()) with
              | `Dirty -> None
              | `Clean _ as state -> Some state
          with _ -> None)

  let download ~key ~dst_path =
    let (module Primary : Backend.S) = primary () in
    match Primary.head_opt ~key () with
      | None -> raise (Backend.Backend_error ("not found: " ^ key))
      | Some _ -> (
          let body = Primary.get ~key () in
          match Manifest.of_string body with
            | `Dirty -> None
            | `Clean manifest as state ->
                assemble_chunks ~manifest ~dst_path (module Primary);
                Some state)
end
