type bigstring =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

external hash_with_seed : string -> int -> int64 = "caml_xxh3_64_with_seed"

external hash_chunks_bigarray_raw : bigstring -> int -> int -> int64 array
  = "caml_xxh3_64_chunks_bigarray"

let hash_hex data seed = Printf.sprintf "%016Lx" (hash_with_seed data seed)

let hash_chunks_bigarray buffer ~length ~chunk_size =
  let raw = hash_chunks_bigarray_raw buffer length chunk_size in
  Array.init
    (Array.length raw / 2)
    (fun i ->
      ( Printf.sprintf "%016Lx" raw.(2 * i),
        Printf.sprintf "%016Lx" raw.((2 * i) + 1) ))
