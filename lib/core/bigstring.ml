type t = (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

external memcmp_ : t -> int -> t -> int -> int -> int = "tsync_bigstring_memcmp"

external blit_from_bytes_ : Bytes.t -> int -> t -> int -> int -> unit
  = "tsync_bigstring_blit_from_bytes"

external blit_to_bytes_ : t -> int -> Bytes.t -> int -> int -> unit
  = "tsync_bigstring_blit_to_bytes"

let create n = Bigarray.Array1.create Bigarray.char Bigarray.c_layout n
let empty = create 0
let length = Bigarray.Array1.dim
let sub t ~off ~len = Bigarray.Array1.sub t off len

let check t off len =
  if off < 0 || len < 0 || off + len > length t then invalid_arg "Bigstring"

let blit_from_bytes b boff t off len =
  if boff < 0 || boff + len > Bytes.length b then invalid_arg "Bigstring";
  check t off len;
  blit_from_bytes_ b boff t off len

let blit_to_bytes t off b boff len =
  if boff < 0 || boff + len > Bytes.length b then invalid_arg "Bigstring";
  check t off len;
  blit_to_bytes_ t off b boff len

let of_string s =
  let t = create (String.length s) in
  blit_from_bytes (Bytes.unsafe_of_string s) 0 t 0 (String.length s);
  t

let to_string ?(off = 0) ?len t =
  let len = match len with Some l -> l | None -> length t - off in
  let b = Bytes.create len in
  blit_to_bytes t off b 0 len;
  Bytes.unsafe_to_string b

let equal a b = length a = length b && memcmp_ a 0 b 0 (length a) = 0

let blit ~src ~src_off ~dst ~dst_off ~len =
  Bigarray.Array1.blit (sub src ~off:src_off ~len) (sub dst ~off:dst_off ~len)

let concat = function
  | [t] -> t
  | l ->
      let t = create (List.fold_left (fun n b -> n + length b) 0 l) in
      ignore
        (List.fold_left
           (fun off b ->
             blit ~src:b ~src_off:0 ~dst:t ~dst_off:off ~len:(length b);
             off + length b)
           0 l);
      t
