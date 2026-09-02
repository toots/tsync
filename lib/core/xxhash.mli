(** Compute the XXH3-64 hash of [data] with the given [seed]. *)
external hash_with_seed : string -> int -> int64 = "caml_xxh3_64_with_seed"

(** {!hash_with_seed} over bytes that are not on the heap, so a chunk body can
    be named where it lies rather than being copied into a string to be read. *)
external hash_bigstring_with_seed : Bigstringaf.t -> int -> int64
  = "caml_xxh3_64_bigstring_with_seed"

(** [hash_hex data seed] returns the XXH3-64 hash of [data] as a 16-character
    lowercase hex string. *)
val hash_hex : string -> int -> string

val hash_bigstring_hex : Bigstringaf.t -> int -> string

(** Length of what {!hash_hex} produces, for the callers that build fixed-width
    names out of it. *)
val hex_length : int

(** Whether a string is shaped like {!hash_hex}'s output.

    Callers name things after digests and then walk a directory full of them,
    where they meet whatever else ended up there. Deciding by what a digest *is*
    skips the unrecognised; deciding by what it is not admits everything nobody
    thought of, which for a caller that copies means copying rubbish and for one
    that deletes means worse. *)
val is_hex : string -> bool

(** Incremental XXH3-64 state for streaming hashes. *)
type state

external create : int -> state = "caml_xxh3_state_create"
external update : state -> string -> unit = "caml_xxh3_state_update"

external update_bigstring : state -> Bigstringaf.t -> unit
  = "caml_xxh3_state_update_bigstring"

external digest : state -> int64 = "caml_xxh3_state_digest"
val digest_hex : state -> string
