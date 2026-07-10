(** Compute the XXH3-64 hash of [data] with the given [seed]. *)
external hash_with_seed : string -> int -> int64 = "caml_xxh3_64_with_seed"

(** [hash_hex data seed] returns the XXH3-64 hash of [data] as a 16-character
    lowercase hex string. *)
val hash_hex : string -> int -> string

(** Incremental XXH3-64 state for streaming hashes. *)
type state

external create : int -> state = "caml_xxh3_state_create"
external update : state -> string -> unit = "caml_xxh3_state_update"
external digest : state -> int64 = "caml_xxh3_state_digest"
val digest_hex : state -> string
