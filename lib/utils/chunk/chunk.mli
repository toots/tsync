(** A chunk body: bytes outside the OCaml heap, either a private mapping of the
    file that holds them or an anonymous off-heap buffer.

    Chunk bodies are the largest thing this program moves (8 MiB by default) and
    the one it never looks inside: they go from a descriptor to a socket and
    back. Held as OCaml strings they would be scanned and copied by a collector
    that has nothing to gain from either. *)

type t

val empty : t
val length : t -> int

(** The bytes themselves, for a caller that reads them. *)
val buffer : t -> Local_io.buffer

val of_string : string -> t
val to_string : t -> string

(** Takes ownership of [buf]. Writing to it afterwards is writing to the chunk.
*)
val of_buffer : Local_io.buffer -> t

(** Off-heap bytes to be filled and then handed to {!of_buffer}. Uninitialised,
    and unlike a mapping the collector is told what one costs and reclaims it
    accordingly. *)
val create : int -> Local_io.buffer

(** A [MAP_PRIVATE] mapping of [len] bytes at [offset] of [path].

    {b Only for a file published by rename and never rewritten in place.} Such a
    file can be unlinked under the mapping — POSIX keeps the inode alive — and
    replaced, the mapping then still serving the bytes it was made from. One
    written in place instead reads as whatever it now holds, and one truncated
    under the mapping is [SIGBUS], which is a dead process rather than a short
    read. Cache group bodies and manifest sidecars qualify; staged bodies and a
    user's own file during an import do not.

    The descriptor is read-only, which is also what makes a short file an error
    here: {!Unix.map_file} grows a file that cannot cover the mapping, and on a
    read-only descriptor that write fails instead. *)
val map_file : path:string -> offset:int -> len:int -> t

val write_to : path:string -> t -> offset:int -> unit Lwt.t

(** XXH3-64 of the whole chunk, as {!Xxhash.hash_hex} spells it. Here rather
    than at the caller so that naming a body never needs it as a string. *)
val hash_hex : t -> int -> string
