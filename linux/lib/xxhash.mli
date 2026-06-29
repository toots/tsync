(** Compute the XXH3-64 hash of [data] with the given [seed]. *)
external hash_with_seed : string -> int -> int64 = "caml_xxh3_64_with_seed"

(** [hash_hex data seed] returns the XXH3-64 hash of [data] as a 16-character
    lowercase hex string. *)
val hash_hex : string -> int -> string
