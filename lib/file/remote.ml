exception Cancelled = S3_client.Cancelled

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = Bytes.create n in
  really_input ic s 0 n;
  close_in ic;
  Bytes.to_string s

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

let upload client ~key ~src_path ~mtime ?(cancel = Atomic.make false)
    ~chunk_prefix () =
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
  List.iter
    (fun (e : Manifest.chunk_entry) ->
      if Atomic.get cancel then raise Cancelled;
      let ck = chunk_prefix ^ Manifest.chunk_key e in
      if S3_client.head_opt client ~key:ck () = None then begin
        let data = read_chunk src_path (e.index * Manifest.chunk_size) e.size in
        S3_client.put client ~content_type:"application/octet-stream" ~key:ck
          ~data ()
      end)
    entries;
  if Atomic.get cancel then raise Cancelled;
  let state =
    Manifest.make ~size:(Int64.of_int file_size) ~chunk_size:Manifest.chunk_size
      ~chunks:entries ~mtime
  in
  S3_client.put client ~content_type:Manifest.content_type ~key
    ~data:(Manifest.to_string state) ();
  state

let download client ~key ~dst_path ~chunk_prefix =
  match S3_client.head_opt client ~key () with
    | None -> raise (S3_client.S3_error ("not found: " ^ key))
    | Some c when c.S3_client.content_type = Some Manifest.content_type -> (
        let body = S3_client.get client ~key () in
        match Manifest.of_string body with
          | `Dirty -> None
          | `Clean manifest as state ->
              let fd =
                Unix.openfile dst_path
                  [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC]
                  0o644
              in
              Unix.ftruncate fd (Int64.to_int manifest.Manifest.size);
              List.iter
                (fun (chunk : Manifest.chunk_entry) ->
                  let ck = chunk_prefix ^ Manifest.chunk_key chunk in
                  let data = S3_client.get client ~key:ck () in
                  ignore
                    (Unix.lseek fd
                       (chunk.index * manifest.Manifest.chunk_size)
                       Unix.SEEK_SET);
                  let written = ref 0 and len = String.length data in
                  while !written < len do
                    written :=
                      !written
                      + Unix.write_substring fd data !written (len - !written)
                  done)
                manifest.Manifest.chunks;
              Unix.close fd;
              Some state)
    | _ ->
        let body = S3_client.get client ~key () in
        let oc = open_out_bin dst_path in
        output_string oc body;
        close_out oc;
        None
