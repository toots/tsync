(** Bytes outside the OCaml heap: {!Bigstringaf}, and the few things this
    program needs of a file's bytes that it does not provide.

    The bodies a store moves are the largest thing here (8 MiB by default) and
    the ones it never looks inside — they go from a descriptor to a socket and
    back. Held as OCaml strings they would be scanned and copied by a collector
    with nothing to gain from either.

    [t] is {!Bigstringaf.t} and says so, which is what lets a buffer cross
    {!Io_lwt.Fs} without a conversion. *)
include module type of Bigstringaf with type t = Bigstringaf.t

(** The whole of [s]. Shadows {!Bigstringaf.of_string}, which takes a range: a
    caller handing over an entire string should not have to spell one. *)
val of_string : string -> t

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
