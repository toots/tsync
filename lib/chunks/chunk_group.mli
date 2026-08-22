(** A run of consecutive chunks, addressed together.

    How many go in a run is [per], which the caller supplies: it is disk
    granularity set against network granularity, and only the cache keeping one
    file per run has an opinion — see {!Chunk_cache.per_group}. Everything here
    is a function of the table and that number. *)

type t

(** [None] only when [i] is out of range: {!Chunk_table} rejects a body whose
    length disagrees with its header, so every index below its count has a key.
*)
val of_table : table:Chunk_table.t -> per:int -> int -> t option

(** Every group of a file, in order. *)
val all : table:Chunk_table.t -> per:int -> t list

(** How many groups a file of this many stored chunks has. *)
val count : table:Chunk_table.t -> per:int -> int

(** Which group stored chunk [i] falls in, for callers that only need to notice
    a boundary crossing. *)
val index_of : per:int -> int -> int

(** The cache file's name: a hash over the member keys, in the same
    ["<h1>-<h2>"] shape as a chunk key. Not ["<first>-<last>"]: two groups can
    share their first and last chunk and differ in between (any run of identical
    chunks does it), and aliasing them onto one file serves the wrong bytes. *)
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
