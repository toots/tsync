(** Compute the XXH3-64 hash of [data] with the given [seed]. *)
external hash_with_seed : string -> int -> int64 = "caml_xxh3_64_with_seed"

(** [hash_hex data seed] returns the XXH3-64 hash of [data] as a 16-character
    lowercase hex string. *)
val hash_hex : string -> int -> string

(** Opaque, cancellable file-hashing state, created from a file path (an
    off-heap copy is kept). The hashing loop polls it, and [hash_state_cancel]
    stops it as soon as the current chunk finishes. *)
type hash_state

val hash_state_create : string -> hash_state
val hash_state_cancel : hash_state -> unit
val hash_state_reset : hash_state -> unit
val hash_state_is_cancelled : hash_state -> bool

(** [hash_file_chunks state ~chunk_size] opens the state's file and reads it in
    [chunk_size]-byte chunks with [pread] into a single reusable buffer,
    returning [Some (file_size, hashes)] with, per chunk, its seed-0 and seed-1
    XXH3-64 hashes as 16-char lowercase hex. Returns [None] if the state was
    cancelled partway through, the file could not be opened, or it was truncated
    mid-read. The runtime lock is released for the whole hash, and the cancel
    flag is polled between chunks. *)
val hash_file_chunks :
  hash_state -> chunk_size:int -> (int * (string * string) array) option
