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

(** [len] bytes from [pos], for a caller reading one field of a body rather than
    the whole of it. *)
val sub : t -> pos:int -> len:int -> string

(** Takes ownership of [buf]. Writing to it afterwards is writing to the chunk.
*)
val of_buffer : Local_io.buffer -> t

(** Off-heap bytes to be filled and then handed to {!of_buffer}. Uninitialised,
    and unlike a mapping the collector is told what one costs and reclaims it
    accordingly. *)
val create : int -> Local_io.buffer

(** A read-only descriptor on the bytes [path] holds now, frozen: a
    copy-on-write clone unlinked the instant it is open, so nothing written to
    [path] afterwards reaches what is read through it, and nothing is left
    behind if the process dies. The caller closes it, and several ranges of one
    file want one of these rather than {!map_file} per range.

    Best effort ({!Device.clone}), logged once per process where it falls
    through: on a filesystem that cannot clone this is the file itself, and the
    caller is back to needing a source nobody rewrites in place or truncates —
    the latter being [SIGBUS] under a mapping, a dead process rather than a
    short read. *)
val open_snapshot : string -> Unix.file_descr

(** A [MAP_PRIVATE] mapping of [len] bytes at [offset] of an {!open_snapshot} of
    [path].

    A short file is an error here rather than a silent grow: {!Unix.map_file}
    extends a file that cannot cover the mapping, and the descriptor being
    read-only is what turns that write into a failure. *)
val map_file : path:string -> offset:int -> len:int -> t

(** {!map_file} against a descriptor already open, which spares a clone and an
    open per range. Read-only, and a snapshot only if the descriptor is one:
    pass {!open_snapshot}'s, not a plain {!Unix.openfile}'s. *)
val map_fd : Unix.file_descr -> offset:int -> len:int -> t

val write_to : path:string -> t -> offset:int -> unit Lwt.t

(** XXH3-64 of the whole chunk, as {!Xxhash.hash_hex} spells it. Here rather
    than at the caller so that naming a body never needs it as a string. *)
val hash_hex : t -> int -> string
