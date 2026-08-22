(** The manifest body as bytes: a fixed-layout header followed by a flat run of
    chunk keys.

    Every field sits at a known offset and chunk [i]'s key is a substring at a
    computed one, so no per-chunk value exists until a caller asks for it —
    which is what makes a 31,230-chunk manifest cheap to open for its name
    alone.

    A local sidecar is {b mapped}, which relies on sidecars only being replaced
    by rename, never rewritten in place — see {!Fs_util.atomic_write}. *)

type t

(** Raised for a body that is truncated, mistyped, or whose header does not
    describe its actual length. *)
exception Malformed of string

val of_string : string -> t

(** Map [path]. Raises {!Malformed} for a body that is not one of ours, and the
    usual [Unix_error] if it cannot be opened. *)
val of_file : string -> t

(** {2 Header} *)

val name : t -> string
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

(** Bytes chunk [i] holds: [chunk_size] for every chunk but the last. Derived
    from the header rather than stored per chunk. *)
val len : t -> int -> int

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
