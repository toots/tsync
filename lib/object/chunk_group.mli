(** Cache chunks: a run of consecutive stored chunks, cached as a single file.

    Stored chunk size is network granularity (smaller: less egress when a file
    changes); cache chunk size is disk granularity (larger: fewer opens, less
    latency). This is the seam — above it callers speak in stored chunk indices,
    below it {!Chunk_cache} stores one file per group. *)

type t

(** Stored chunks per cache chunk: the [n >= 1] minimizing
    [|n * chunk_size - cache_chunk_size|]. A tie takes the larger group. *)
val per_group : chunk_size:int -> cache_chunk_size:int -> int

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
