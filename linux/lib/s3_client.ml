open Lwt.Infix
module S3 = Aws_s3_lwt.S3

exception S3_error of string

type file_entry = {
  key : string;
  size : int;
  last_modified : float;
  content_type : string option;
}

type t = {
  bucket : string;
  credentials : Aws_s3.Credentials.t;
  endpoint : Aws_s3.Region.endpoint;
}

let make ~bucket ~region ~access_key_id ~secret_access_key =
  let credentials =
    Aws_s3.Credentials.make ~access_key:access_key_id
      ~secret_key:secret_access_key ()
  in
  let endpoint =
    Aws_s3.Region.endpoint ~inet:`V4 ~scheme:`Https
      (Aws_s3.Region.of_string region)
  in
  { bucket; credentials; endpoint }

let string_of_error = function
  | S3.Redirect _ -> "redirect"
  | S3.Throttled -> "throttled"
  | S3.Unknown (code, msg) -> Printf.sprintf "unknown(%d): %s" code msg
  | S3.Failed exn -> Printexc.to_string exn
  | S3.Forbidden -> "forbidden"
  | S3.Not_found -> "not found"

(* Global mutex: Lwt event loop must run in one thread at a time *)
let lwt_mutex = Mutex.create ()

let lwt_run f =
  Mutex.lock lwt_mutex;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock lwt_mutex)
    (fun () -> Lwt_main.run (f ()))

let s3_eio msg = Unix.Unix_error (Unix.EIO, "s3", msg)

let unwrap op = function
  | Ok v -> v
  | Error e ->
      let msg = string_of_error e in
      Log.err "s3 %s: %s" op msg;
      raise (s3_eio msg)

let put t ?content_type ~key ~data () =
  ignore
    (lwt_run (fun () ->
         S3.put ~credentials:t.credentials ~endpoint:t.endpoint ?content_type
           ~bucket:t.bucket ~key ~data ()
         >|= unwrap "put"))

let get t ~key () =
  lwt_run (fun () ->
      S3.get ~credentials:t.credentials ~endpoint:t.endpoint ~bucket:t.bucket
        ~key ()
      >|= unwrap "get")

let head_opt t ~key () =
  lwt_run (fun () ->
      S3.head ~credentials:t.credentials ~endpoint:t.endpoint ~bucket:t.bucket
        ~key ()
      >|= function
      | Ok c ->
          Some
            {
              key = c.S3.key;
              size = c.S3.size;
              last_modified = c.S3.last_modified;
              content_type = c.S3.content_type;
            }
      | Error S3.Not_found -> None
      | Error e ->
          let msg = string_of_error e in
          Log.err "s3 head %s: %s" key msg;
          raise (s3_eio msg))

let delete t ~key () =
  lwt_run (fun () ->
      S3.delete ~credentials:t.credentials ~endpoint:t.endpoint ~bucket:t.bucket
        ~key ()
      >|= unwrap "delete")

let delete_multi t keys =
  let open S3.Delete_multi in
  let rec go = function
    | [] -> ()
    | batch ->
        let n = min 1000 (List.length batch) in
        let here = List.filteri (fun i _ -> i < n) batch in
        let rest = List.filteri (fun i _ -> i >= n) batch in
        let objects = List.map (fun key -> { key; version_id = None }) here in
        ignore
          (lwt_run (fun () ->
               S3.delete_multi ~credentials:t.credentials ~endpoint:t.endpoint
                 ~bucket:t.bucket ~objects ()
               >|= unwrap "delete_multi"));
        go rest
  in
  go keys

let copy t ~src_key ~dst_key () =
  let data = get t ~key:src_key () in
  let content_type =
    match head_opt t ~key:src_key () with
      | Some c -> c.content_type
      | None -> None
  in
  put t ?content_type ~key:dst_key ~data ()

(* List all objects under prefix, paginating through continuations *)
let list_all t ~prefix () =
  let entry_of c =
    {
      key = c.S3.key;
      size = c.S3.size;
      last_modified = c.S3.last_modified;
      content_type = c.S3.content_type;
    }
  in
  let rec collect acc cont =
    match cont with
      | S3.Ls.Done -> Lwt.return acc
      | S3.Ls.More f -> (
          f () >>= function
          | Ok (items, next) -> collect (acc @ List.map entry_of items) next
          | Error e -> Lwt.fail (s3_eio (string_of_error e)))
  in
  lwt_run (fun () ->
      S3.ls ~credentials:t.credentials ~endpoint:t.endpoint ~bucket:t.bucket
        ~prefix ()
      >>= function
      | Ok (items, cont) -> collect (List.map entry_of items) cont
      | Error e ->
          let msg = string_of_error e in
          Log.err "s3 ls %s: %s" prefix msg;
          Lwt.fail (s3_eio msg))

(* Simulate delimiter='/' — returns (files, subdir_names) relative to prefix *)
let list_directory t ~prefix () =
  let prefix_len = String.length prefix in
  let all = list_all t ~prefix () in
  let dirs = Hashtbl.create 16 in
  let files = ref [] in
  List.iter
    (fun e ->
      if String.length e.key <= prefix_len then ()
      else begin
        let rest =
          String.sub e.key prefix_len (String.length e.key - prefix_len)
        in
        match String.index_opt rest '/' with
          | None -> files := e :: !files
          | Some i -> Hashtbl.replace dirs (String.sub rest 0 i) ()
      end)
    all;
  let subdirs = Hashtbl.fold (fun k () acc -> k :: acc) dirs [] in
  (List.rev !files, List.sort String.compare subdirs)

(* ── File I/O helpers ────────────────────────────────────────────────────── *)

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

(* ── Chunked upload ──────────────────────────────────────────────────────── *)

let put_chunked t ~key ~src_path ~chunk_prefix =
  let file_size = (Unix.stat src_path).Unix.st_size in
  if file_size <= Chunk_manifest.chunk_size then
    put t ~content_type:"application/octet-stream" ~key
      ~data:(read_file src_path) ()
  else begin
    let num_chunks =
      (file_size + Chunk_manifest.chunk_size - 1) / Chunk_manifest.chunk_size
    in
    let entries =
      List.init num_chunks (fun i ->
          let offset = i * Chunk_manifest.chunk_size in
          let len = min Chunk_manifest.chunk_size (file_size - offset) in
          let data = read_chunk src_path offset len in
          Chunk_manifest.
            {
              index = i;
              h1 = Xxhash.hash_hex data 0;
              h2 = Xxhash.hash_hex data 1;
              size = len;
            })
    in
    List.iter
      (fun (e : Chunk_manifest.chunk_entry) ->
        let ck = chunk_prefix ^ Chunk_manifest.chunk_key e in
        if head_opt t ~key:ck () = None then begin
          let data =
            read_chunk src_path (e.index * Chunk_manifest.chunk_size) e.size
          in
          put t ~content_type:"application/octet-stream" ~key:ck ~data ()
        end)
      entries;
    let manifest =
      Chunk_manifest.
        {
          v = 1;
          size = Int64.of_int file_size;
          chunk_size = Chunk_manifest.chunk_size;
          chunks = entries;
        }
    in
    put t ~content_type:Chunk_manifest.content_type ~key
      ~data:(Chunk_manifest.to_string manifest)
      ()
  end

(* ── Chunked download ────────────────────────────────────────────────────── *)

let get_chunked t ~key ~dst_path ~chunk_prefix =
  match head_opt t ~key () with
    | None -> raise (S3_error ("not found: " ^ key))
    | Some c when c.content_type = Some Chunk_manifest.content_type ->
        let body = get t ~key () in
        let manifest = Chunk_manifest.of_string body in
        let fd =
          Unix.openfile dst_path
            [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC]
            0o644
        in
        Unix.ftruncate fd (Int64.to_int manifest.size);
        List.iter
          (fun (chunk : Chunk_manifest.chunk_entry) ->
            let ck = chunk_prefix ^ Chunk_manifest.chunk_key chunk in
            let data = get t ~key:ck () in
            ignore
              (Unix.lseek fd (chunk.index * manifest.chunk_size) Unix.SEEK_SET);
            let written = ref 0 and len = String.length data in
            while !written < len do
              written :=
                !written + Unix.write_substring fd data !written (len - !written)
            done)
          manifest.chunks;
        Unix.close fd
    | _ ->
        let body = get t ~key () in
        let oc = open_out_bin dst_path in
        output_string oc body;
        close_out oc
