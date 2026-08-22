(* The manifest body, as bytes.

   A fixed-layout record followed by a flat run of chunk keys. Nothing is parsed:
   every field is at a known offset and chunk [i]'s key is a substring at
   [keys_at + i * key_bytes], with no per-chunk allocation until a caller asks
   for one.

   {b The mapping relies on the write discipline.} Sidecars are only replaced by
   rename ({!Fs_util.atomic_write}), never rewritten in place, so a mapping keeps
   its inode and truncating one in place would fault every reader mapping it.

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

(* ["<h1>-<h2>"], two 16-character hex digests, stored verbatim so reading one
   is a substring and never a concatenation. *)
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

(* Mapped rather than read, so the chunk keys cost no heap; the descriptor
   closes immediately, the mapping holding its own reference. *)
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
   per-chunk length would be 12 bytes each restating two header fields. *)
let len t i =
  if t.chunk_size <= 0 then 0
  else max 0 (min t.chunk_size (Int64.to_int t.size - (i * t.chunk_size)))

(* Written a byte at a time, the way it is read: the accessors above are the
   only description of the layout, and a writer using wider primitives would be
   a second one to keep in step. *)
let put_bytes buf off s =
  String.iteri (fun i c -> Bigarray.Array1.unsafe_set buf (off + i) c) s

let put_int32 buf off v =
  for i = 0 to 3 do
    Bigarray.Array1.unsafe_set buf (off + i)
      (Char.unsafe_chr ((v lsr (i * 8)) land 0xff))
  done

let put_int64 buf off v =
  for i = 0 to 7 do
    Bigarray.Array1.unsafe_set buf (off + i)
      (Char.unsafe_chr
         (Int64.to_int
            (Int64.logand (Int64.shift_right_logical v (i * 8)) 0xFFL)))
  done

type builder = { buf : Local_io.buffer; b_keys_at : int; b_count : int }

(* Zeroed rather than left as {!Bigstring.create} hands it over, so a key never set
   is a key of NUL bytes the store cannot hold rather than whatever the page
   last held. *)
let builder ~name ~size ~chunk_size ~mtime ~symlink ~count =
  if count < 0 then
    invalid_arg (Printf.sprintf "Chunk_table.builder: count %d" count);
  let link = Option.value symlink ~default:"" in
  let keys_at = header_bytes + String.length name + String.length link in
  let buf = Bigstring.create (keys_at + (count * key_bytes)) in
  Local_io.zero buf ~pos:0 ~len:(Bigarray.Array1.dim buf);
  put_bytes buf 0 magic;
  put_int64 buf 8 size;
  put_int64 buf 16 (Int64.bits_of_float mtime);
  put_int32 buf 24 chunk_size;
  put_int32 buf 28 count;
  put_int32 buf 32 (String.length name);
  put_int32 buf 36 (String.length link);
  put_bytes buf header_bytes name;
  put_bytes buf (header_bytes + String.length name) link;
  { buf; b_keys_at = keys_at; b_count = count }

let key_offset b i =
  if i < 0 || i >= b.b_count then
    invalid_arg (Printf.sprintf "Chunk_table.builder: %d of %d" i b.b_count);
  b.b_keys_at + (i * key_bytes)

let set b i key =
  let off = key_offset b i in
  if String.length key <> key_bytes then
    invalid_arg (Printf.sprintf "Chunk_table.set: chunk key %S" key);
  put_bytes b.buf off key

let get b i =
  let off = key_offset b i in
  String.init key_bytes (fun k -> Bigarray.Array1.unsafe_get b.buf (off + k))

let builder_count b = b.b_count

let seal b ~h1 ~h2 =
  let fixed_hex what s =
    if String.length s <> 16 then
      invalid_arg (Printf.sprintf "Chunk_table.seal: %s is %S" what s)
  in
  fixed_hex "h1" h1;
  fixed_hex "h2" h2;
  put_bytes b.buf 40 h1;
  put_bytes b.buf 56 h2;
  b.buf

let of_chunk c = of_source (Mapped c)
let bytes t = match t.src with Mapped m -> m | Str s -> Bigstring.of_string s

let encode ~name ~size ~chunk_size ~mtime ~h1 ~h2 ~symlink ~keys =
  let b =
    builder ~name ~size ~chunk_size ~mtime ~symlink ~count:(List.length keys)
  in
  List.iteri (set b) keys;
  Bigstring.to_string (seal b ~h1 ~h2)
