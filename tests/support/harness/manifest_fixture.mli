(** Building a manifest from chunk keys, which only a test does: an upload fills
    a builder as it hashes and publishes with the digests it accumulated, so
    nothing shipping needs this shape. *)

type chunk_entry = { index : int; h1 : string; h2 : string; size : int }

val chunk_key : chunk_entry -> string

(** The two digests are the key's halves. *)
val entry_of_key : index:int -> size:int -> string -> chunk_entry

val make :
  name:string ->
  h1:string ->
  h2:string ->
  size:int64 ->
  chunk_size:int ->
  chunks:chunk_entry list ->
  mtime:float ->
  Manifest.t
