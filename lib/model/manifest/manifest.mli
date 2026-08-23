(** A published file's metadata, which is the body it was decoded from: the
    header fields are answered by reading it rather than copied out beside it,
    so a 32 GB file's 31,230 chunk keys are never materialized to answer what
    the file is called.

    No name: a name belongs to where a manifest is filed, and the body carries
    one only because some locations cannot yield it — a backend key is
    [<folder-id>/<hash>], an escaped cache leaf is [.tsync-esc-<hash>], and both
    are one-way. *)
type t

(** Raised for a body that is truncated, mistyped, or whose header does not
    describe its actual length. *)
exception Malformed of string

val of_string : string -> t

(** Map [path]. Raises {!Malformed} for a body that is not one of ours, and the
    usual [Unix_error] if it cannot be opened. *)
val of_file : string -> t

(** {2 Header} *)

val size : t -> int64
val chunk_size : t -> int
val mtime : t -> float
val h1 : t -> string
val h2 : t -> string
val symlink : t -> string option

(** {2 Chunks} *)

(** How many chunk keys the body carries. An empty file has one (of length
    zero); a symlink has none. *)
val count : t -> int

(** Chunk [i]'s key, ["<h1>-<h2>"], stored verbatim so this is one substring and
    never a concatenation. Raises [Invalid_argument] outside [0, count). *)
val key : t -> int -> string

(** {2 Writing} *)

(** Serialize a body. [keys] are the chunk keys in index order, each exactly as
    {!key} returns them. Raises [Invalid_argument] for a digest or key of the
    wrong width — a body that would not round-trip must not reach the disk. *)
val encode :
  name:string ->
  size:int64 ->
  chunk_size:int ->
  mtime:float ->
  h1:string ->
  h2:string ->
  symlink:string option ->
  keys:string list ->
  string

(** A body being filled a key at a time, for an upload whose chunks finish out
    of order.

    [count] is fixed at {!builder}, so every key has an address and none is held
    anywhere but in the body itself — a terabyte's worth is 4 MB of buffer and
    no OCaml heap at all. The two whole-file digests are a function of the keys
    and so are stamped at {!seal}. *)
type builder

val builder :
  name:string ->
  size:int64 ->
  chunk_size:int ->
  mtime:float ->
  symlink:string option ->
  count:int ->
  builder

(** Chunk [i]'s key. Raises [Invalid_argument] for a key of the wrong width or
    an index outside [0, count). *)
val set : builder -> int -> string -> unit

val get : builder -> int -> string
val builder_count : builder -> int

(** The finished body, which is the buffer itself and not a copy of it. *)
val seal : builder -> h1:string -> h2:string -> Bigstring.t

(** A body a caller already holds as bytes, mapped or built. *)
val of_chunk : Bigstring.t -> t

(** The body itself, which is a copy only where {!t} was decoded from a string.
*)
val bytes : t -> Bigstring.t

(** The name the body records. Only the location can say whether this is worth
    consulting, so a caller holding a key uses the key instead. *)
val recorded_name : t -> string

(** {!digest_of_chunks} over a body being built, which addresses its keys rather
    than holding them: [len] answers what {!Chunks.length_of} would, so the two
    agree on the same file. *)
val digest_of_keys :
  count:int -> key:(int -> string) -> len:(int -> int) -> string * string

(** A chunkless manifest representing a symlink to [target]. *)
val make_symlink : name:string -> target:string -> mtime:float -> t

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

(** The enclosing type, nameable from inside {!Group} where [t] is the group's
    own. *)
type manifest = t

(** A run of consecutive chunks, cached as one local file.

    The two granularities pull opposite ways: a stored chunk is network
    granularity, a cache chunk is disk granularity. This is the seam, and the
    only place knowing a cache file holds more than one stored chunk. *)
module Group : sig
  type t

  (** [None] only when [i] is out of range: decoding rejects a body whose length
      disagrees with its header, so every index below its count has a key. *)
  val of_table : table:manifest -> per:int -> int -> t option

  (** Every group of a file, in order. *)
  val all : table:manifest -> per:int -> t list

  (** How many groups a file of this many stored chunks has. *)
  val count : table:manifest -> per:int -> int

  (** Which group stored chunk [i] falls in, for callers that only need to
      notice a boundary crossing. *)
  val index_of : per:int -> int -> int

  (** The cache file's name: a hash over the member keys, in the same
      ["<h1>-<h2>"] shape as a chunk key. Not ["<first>-<last>"]: two groups can
      share their first and last chunk and differ in between (any run of
      identical chunks does it), and aliasing them onto one file serves the
      wrong bytes. *)
  val key : t -> string

  val member_count : t -> int

  (** The stored chunk indices this group covers, in order. *)
  val indices : t -> int list

  (** Byte offset of stored chunk [i] within the group body. *)
  val offset : t -> int -> int

  (** Bytes stored chunk [i] holds. *)
  val size : t -> int -> int

  (** The chunk key stored chunk [i] was published under. *)
  val member_key : t -> int -> string

  (** Total length of the group body. *)
  val bytes : t -> int
end
