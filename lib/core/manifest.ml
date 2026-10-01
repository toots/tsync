let magic = "tsyncm03"
let header = 72

type t = {
  body : string;
  size : int;
  mtime : float;
  chunk_size : int;
  count : int;
  name : string;
  link : string option;
  h1 : string;
  h2 : string;
}

let u32 s o = Int32.to_int (String.get_int32_le s o) land 0xffffffff

let decode body =
  let n = String.length body in
  if n < header || String.sub body 0 8 <> magic then None
  else (
    let size = Int64.to_int (String.get_int64_le body 8) in
    let mtime = Int64.float_of_bits (String.get_int64_le body 16) in
    let chunk_size = u32 body 24
    and count = u32 body 28
    and name_len = u32 body 32
    and link_len = u32 body 36 in
    let expected = header + name_len + link_len + (33 * count) in
    if size < 0 || count > (max_int - header) / 33 || expected <> n then None
    else
      Some
        {
          body;
          size;
          mtime;
          chunk_size;
          count;
          name = String.sub body header name_len;
          link =
            (if link_len = 0 then None
             else Some (String.sub body (header + name_len) link_len));
          h1 = String.sub body 40 16;
          h2 = String.sub body 56 16;
        })

let has_magic body =
  let m = String.length magic in
  Bigstring.length body >= m && Bigstring.to_string ~len:m body = magic

(* Only a body carrying the magic is copied off the bigstring and decoded. *)
let of_body body =
  if has_magic body then decode (Bigstring.to_string body) else None

let is_manifest body = of_body body <> None

let keys_offset m =
  header + String.length m.name
  + match m.link with Some l -> String.length l | None -> 0

(* Keys are read when used; a malformed one is never fetched or trusted. *)
let key m i =
  if i < 0 || i >= m.count then
    Fail.corrupt "manifest %S has no chunk %d" m.name i
  else (
    let s = String.sub m.body (keys_offset m + (33 * i)) 33 in
    match Chunk_key.of_string s with
      | Some k -> k
      | None -> Fail.corrupt "manifest %S: malformed chunk key %S" m.name s)

let keys m = List.init m.count (key m)

let chunk_names body =
  match of_body body with
    | None -> Ok []
    | Some m -> (
        match keys m with
          | ks -> Ok ks
          | exception Fail.E e -> Error (Fail.to_string e))

let is_link m = m.link <> None

(* 02 §2.1: the dual digest of "<key>-<length>;" over the chunks, in order. *)
let digest_of ~size ~cs keys =
  let st = Xxh.dual_create () in
  List.iteri
    (fun i k ->
      let s =
        Printf.sprintf "%s-%d;" (Chunk_key.to_string k)
          (Chunking.length ~size ~cs i)
      in
      Xxh.dual_update_string st s 0 (String.length s))
    keys;
  match String.split_on_char '-' (Xxh.dual_digest st) with
    | [a; b] -> (a, b)
    | _ -> assert false

let encode ~name ~size ~mtime ~chunk_size ?link ~h1 ~h2 keys =
  let b =
    Buffer.create (header + String.length name + (33 * List.length keys))
  in
  Buffer.add_string b magic;
  Buffer.add_int64_le b (Int64.of_int size);
  Buffer.add_int64_le b (Int64.bits_of_float mtime);
  Buffer.add_int32_le b (Int32.of_int chunk_size);
  Buffer.add_int32_le b (Int32.of_int (List.length keys));
  Buffer.add_int32_le b (Int32.of_int (String.length name));
  Buffer.add_int32_le b
    (Int32.of_int (match link with Some l -> String.length l | None -> 0));
  Buffer.add_string b h1;
  Buffer.add_string b h2;
  Buffer.add_string b name;
  Option.iter (Buffer.add_string b) link;
  List.iter (fun k -> Buffer.add_string b (Chunk_key.to_string k)) keys;
  Buffer.contents b

let make ~name ~size ~mtime ~chunk_size keys =
  let h1, h2 = digest_of ~size ~cs:chunk_size keys in
  Option.get (decode (encode ~name ~size ~mtime ~chunk_size ~h1 ~h2 keys))

let symlink ~name ~mtime target =
  let d = Xxh.dual target in
  let h1 = String.sub d 0 16 and h2 = String.sub d 17 16 in
  Option.get
    (decode
       (encode ~name ~size:(String.length target) ~mtime
          ~chunk_size:Chunking.default_chunk_size ~link:target ~h1 ~h2 []))

(* The recorded name is the leaf of the key a body is written to. *)
let rename m name =
  if m.name = name then m
  else
    Option.get
      (decode
         (encode ~name ~size:m.size ~mtime:m.mtime ~chunk_size:m.chunk_size
            ?link:m.link ~h1:m.h1 ~h2:m.h2 (keys m)))

let with_mtime m mtime =
  Option.get
    (decode
       (encode ~name:m.name ~size:m.size ~mtime ~chunk_size:m.chunk_size
          ?link:m.link ~h1:m.h1 ~h2:m.h2 (keys m)))

let content_id m = m.h1

(* A reader accepts any chunk size in [1, CHUNK_SIZE_READ_MAX], and a count
   covering the size; anything else reads as damaged. *)
let check_readable m =
  if m.link = None then (
    if m.chunk_size < 1 || m.chunk_size > Chunking.chunk_size_read_max then
      Fail.corrupt "manifest %S: chunk size %d" m.name m.chunk_size;
    if m.count < Chunking.count ~size:m.size ~cs:m.chunk_size then
      Fail.corrupt "manifest %S: a hole in its chunk list" m.name)

let equal_content a b =
  a.h1 = b.h1 && a.h2 = b.h2 && a.size = b.size && a.link = b.link
