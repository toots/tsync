(** A published file's metadata, which is the body it was decoded from: the
    header fields are answered by reading it rather than copied out beside it,
    so a 32 GB file's 31,230 chunk keys are never materialized to answer what
    the file is called.

    No name: a name belongs to where a manifest is filed, and the body carries
    one only because some locations cannot yield it — a backend key is
    [<folder-id>/<hash>], an escaped cache leaf is [.tsync-esc-<hash>], and both
    are one-way. *)
type t = Chunk_table.t

val size : t -> int64
val chunk_size : t -> int
val mtime : t -> float
val h1 : t -> string
val h2 : t -> string
val symlink : t -> string option

(** What an upload produces per chunk. Read paths go through {!Chunk_table}. *)
type chunk_entry = { index : int; h1 : string; h2 : string; size : int }

val chunk_key : chunk_entry -> string

(** The reverse, for a chunk kept from a previous upload. Raises
    [Invalid_argument] for a key that is not ["<h1>-<h2>"]. *)
val entry_of_key : index:int -> size:int -> string -> chunk_entry

(** Whole-file [h1]/[h2] as a hash over the ordered chunk digests, so a changed
    file's manifest is rebuildable from its chunk entries alone. *)
val digest_of_chunks : chunk_entry list -> string * string

(** {!digest_of_chunks} over a body being built, which addresses its keys rather
    than holding them: [len] answers what {!Chunks.length_of} would, so the two
    agree on the same file. *)
val digest_of_keys :
  count:int -> key:(int -> string) -> len:(int -> int) -> string * string

val make :
  name:string ->
  h1:string ->
  h2:string ->
  size:int64 ->
  chunk_size:int ->
  chunks:chunk_entry list ->
  mtime:float ->
  t

(** A chunkless manifest representing a symlink to [target]. *)
val make_symlink : name:string -> target:string -> mtime:float -> t

val of_string : string -> t

(** [path]'s body, mapped rather than read: chunk keys cost no heap and the
    pages are reclaimable. Raises the way {!Chunk_table.of_file} does. *)
val of_file : string -> t

(** A body a caller already holds as bytes, which is what {!Chunk_table.seal}
    hands back. *)
val of_chunk : Bigstring.t -> t

(** The name recorded in the body. Meaningful only where the location cannot
    yield one; a caller holding a key takes the name from the key. *)
val recorded_name : t -> string

(** Encoding needs a name, so every caller states which one; the two that file a
    manifest under a key that does not describe it — a version snapshot, a
    trashed marker — are then the only ones passing other than the key's leaf.
*)
val to_string : name:string -> t -> string

(** {!to_string} as the bytes a store and a sidecar are both handed, which for a
    manifest already recording [name] is the body it is made of rather than a
    fresh encoding of it. *)
val body : name:string -> t -> Bigstring.t
