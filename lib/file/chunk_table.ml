(* The manifest body, as bytes.

   A fixed-layout record followed by a flat run of chunk keys. Nothing is parsed:
   every field is at a known offset and chunk [i]'s key is a substring at
   [keys_at + i * key_bytes], with no per-chunk allocation until a caller asks
   for one. A 32 GB file at a 1 MiB chunk size carries 31,230 keys, and opening
   it for its name costs a few microseconds.

   A local sidecar is mapped, so those bytes live in the page cache: file-backed,
   clean, reclaimable, released when the value is collected. A body fetched from
   a backend is a string and is read identically.

   {b The mapping relies on the write discipline.} Sidecars are only replaced by
   rename ({!Fs_util.atomic_write}), never rewritten in place, so a mapping keeps
   its inode and its bytes stay valid while held. Truncating one in place would
   fault every reader mapping it.

   Layout (little-endian, offsets in bytes):
   {v
     0   8   magic "tsyncm03"
     8   8   size       int64   logical file size
     16  8   mtime      float   IEEE bits
     24  4   chunk_size int32
     28  4   count      int32   chunk keys that follow
     32  4   name_len   int32
     36  4   link_len   int32   0 for a regular file
     40  16  h1                 whole-file digest, hex
     56  16  h2
     72      name bytes, then symlink target bytes, then count * 33 chunk keys
   v}
   Every variable-length field is length-prefixed, so nothing needs escaping: a
   leaf name is an arbitrary byte string. *)

type bytes_source =
  | Mapped of
      (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
  | Str of string

type t = {
  src : bytes_source;
  count : int;
  chunk_size : int;
  size : int64;
  mtime : float;
  name : string;
  symlink : string option;
  h1 : string;
  h2 : string;
  keys_at : int;
}

exception Malformed of string

let magic = "tsyncm03"
let header_bytes = 72

(* ["<h1>-<h2>"], two 16-character hex digests — the spelling every other layer
   uses, stored verbatim so reading one is a substring and never a
   concatenation. *)
let key_bytes = 33

let length = function
  | Mapped m -> Bigarray.Array1.dim m
  | Str s -> String.length s

let unsafe_sub src off len =
  match src with
    | Str s -> String.sub s off len
    | Mapped m ->
        String.init len (fun i -> Bigarray.Array1.unsafe_get m (off + i))

let sub src off len =
  if off < 0 || len < 0 || off + len > length src then
    raise (Malformed "truncated manifest");
  unsafe_sub src off len

let byte src off =
  match src with
    | Str s -> Char.code (String.unsafe_get s off)
    | Mapped m -> Char.code (Bigarray.Array1.unsafe_get m off)

let int32_at src off =
  byte src off
  lor (byte src (off + 1) lsl 8)
  lor (byte src (off + 2) lsl 16)
  lor (byte src (off + 3) lsl 24)

let int64_at src off =
  let r = ref 0L in
  for i = 7 downto 0 do
    r := Int64.logor (Int64.shift_left !r 8) (Int64.of_int (byte src (off + i)))
  done;
  !r

let size_prefix_bytes = 16

(* Enough of a body to answer how big the file is. Summing sizes over a whole
   domain reads this much per sidecar and maps nothing: one mapping per file,
   released only at the next collection, is what makes {!of_file} the wrong tool
   for tens of thousands of them. *)
let size_of_prefix s =
  let src = Str s in
  if length src < size_prefix_bytes || sub src 0 8 <> magic then None
  else Some (int64_at src 8)

(* Validating the length once here is what lets every accessor below skip bounds
   checks: after this, chunk [i] for [i < count] is in range. *)
let of_source src =
  if length src < header_bytes then raise (Malformed "short manifest");
  if sub src 0 8 <> magic then raise (Malformed "bad magic");
  let size = int64_at src 8 in
  let mtime = Int64.float_of_bits (int64_at src 16) in
  let chunk_size = int32_at src 24 in
  let count = int32_at src 28 in
  let name_len = int32_at src 32 in
  let link_len = int32_at src 36 in
  if count < 0 || name_len < 0 || link_len < 0 || chunk_size < 0 then
    raise (Malformed "negative length");
  let keys_at = header_bytes + name_len + link_len in
  let expected = keys_at + (count * key_bytes) in
  if length src <> expected then
    raise
      (Malformed
         (Printf.sprintf "body is %d bytes, header describes %d" (length src)
            expected));
  {
    src;
    count;
    chunk_size;
    size;
    mtime;
    h1 = sub src 40 16;
    h2 = sub src 56 16;
    name = sub src header_bytes name_len;
    symlink =
      (if link_len = 0 then None
       else Some (sub src (header_bytes + name_len) link_len));
    keys_at;
  }

let of_string s = of_source (Str s)

(* Mapped rather than read, so the chunk keys cost no heap and the pages are
   reclaimable. The descriptor closes immediately, the mapping holding its own
   reference. *)
let of_file path =
  let fd = Unix.openfile path [Unix.O_RDONLY] 0 in
  let map =
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        Bigarray.array1_of_genarray
          (Unix.map_file fd Bigarray.char Bigarray.c_layout false [| -1 |]))
  in
  of_source (Mapped map)

let count t = t.count
let chunk_size t = t.chunk_size
let size t = t.size
let mtime t = t.mtime
let name t = t.name
let symlink t = t.symlink
let h1 t = t.h1
let h2 t = t.h2

let key t i =
  if i < 0 || i >= t.count then
    invalid_arg (Printf.sprintf "Chunk_table.key: %d of %d" i t.count);
  unsafe_sub t.src (t.keys_at + (i * key_bytes)) key_bytes

(* Derived, not stored: every chunk is [chunk_size] except the last, so a
   per-chunk length would be 12 bytes each restating two header fields. An empty
   file still has one chunk, of length zero. *)
let len t i =
  if t.chunk_size <= 0 then 0
  else max 0 (min t.chunk_size (Int64.to_int t.size - (i * t.chunk_size)))

let encode ~name ~size ~chunk_size ~mtime ~h1 ~h2 ~symlink ~keys =
  let link = Option.value symlink ~default:"" in
  let count = List.length keys in
  let b =
    Buffer.create (header_bytes + String.length name + (count * key_bytes))
  in
  let i32 v =
    let s = Bytes.create 4 in
    Bytes.set_int32_le s 0 (Int32.of_int v);
    Buffer.add_bytes b s
  in
  let i64 v =
    let s = Bytes.create 8 in
    Bytes.set_int64_le s 0 v;
    Buffer.add_bytes b s
  in
  let fixed_hex what s =
    if String.length s <> 16 then
      invalid_arg (Printf.sprintf "Chunk_table.encode: %s is %S" what s);
    Buffer.add_string b s
  in
  Buffer.add_string b magic;
  i64 size;
  i64 (Int64.bits_of_float mtime);
  i32 chunk_size;
  i32 count;
  i32 (String.length name);
  i32 (String.length link);
  fixed_hex "h1" h1;
  fixed_hex "h2" h2;
  Buffer.add_string b name;
  Buffer.add_string b link;
  List.iter
    (fun k ->
      if String.length k <> key_bytes then
        invalid_arg (Printf.sprintf "Chunk_table.encode: chunk key %S" k);
      Buffer.add_string b k)
    keys;
  Buffer.contents b
