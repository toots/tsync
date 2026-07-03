type bigstring =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

(** Compute the XXH3-64 hash of [data] with the given [seed]. *)
external hash_with_seed : string -> int -> int64 = "caml_xxh3_64_with_seed"

(** [hash_hex data seed] returns the XXH3-64 hash of [data] as a 16-character
    lowercase hex string. *)
val hash_hex : string -> int -> string

(** [hash_hex_bigarray buffer ~length seed] hashes the first [length] bytes of
    [buffer]. The OCaml runtime lock is released while hashing, so concurrent
    hashing threads run in parallel. *)
val hash_hex_bigarray : bigstring -> length:int -> int -> string
