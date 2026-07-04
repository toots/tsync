type bigstring =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

(** Compute the XXH3-64 hash of [data] with the given [seed]. *)
external hash_with_seed : string -> int -> int64 = "caml_xxh3_64_with_seed"

(** [hash_hex data seed] returns the XXH3-64 hash of [data] as a 16-character
    lowercase hex string. *)
val hash_hex : string -> int -> string

(** [hash_chunks_bigarray buffer ~length ~chunk_size] hashes the first [length]
    bytes of [buffer] split into [chunk_size]-byte chunks (the last possibly
    shorter), returning per chunk the seed-0 and seed-1 XXH3-64 hashes as
    16-character lowercase hex. The OCaml runtime lock is released for the whole
    loop, so a single call (one detach) hashes an entire file. *)
val hash_chunks_bigarray :
  bigstring -> length:int -> chunk_size:int -> (string * string) array
