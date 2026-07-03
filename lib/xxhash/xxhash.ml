type bigstring =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

external hash_with_seed : string -> int -> int64 = "caml_xxh3_64_with_seed"

external hash_bigarray_with_seed : bigstring -> int -> int -> int64
  = "caml_xxh3_64_bigarray_with_seed"

let hash_hex data seed = Printf.sprintf "%016Lx" (hash_with_seed data seed)

let hash_hex_bigarray buffer ~length seed =
  Printf.sprintf "%016Lx" (hash_bigarray_with_seed buffer length seed)
