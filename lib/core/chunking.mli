(** Fixed-size chunking (spec 01 §3.4, §3.5). *)

(** Chunks cutting [size] bytes: 0 for an empty file. *)
val count : size:int -> cs:int -> int

(** Chunk keys a regular-file manifest names: at least one, the empty chunk for
    an empty file (02 §2.2). *)
val manifest_count : size:int -> cs:int -> int

val offset : cs:int -> int -> int
val length : size:int -> cs:int -> int -> int
val index : cs:int -> int -> int

(** One chunk's part of a range: chunk index, offset inside the chunk, length,
    and offset inside the caller's buffer. *)
type piece = { index : int; off : int; len : int; buf_off : int }

(** Cover [\[off, off + len)] exactly once, clipped at the end of chunk
    [count - 1]; empty for a non-positive chunk size or length, or a negative
    offset. *)
val pieces : cs:int -> count:int -> off:int -> len:int -> piece list

val default_chunk_size : int

(** Bounds on what a writer may choose. *)
val chunk_size_min : int

val chunk_size_max : int

(** The largest chunk size a reader accepts. *)
val chunk_size_read_max : int
