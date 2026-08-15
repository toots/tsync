(** Bytes outside the OCaml heap. Spelled as {!Bigstringaf.t} rather than the
    Bigarray type it abbreviates so that its fast blits and comparisons are
    available wherever a buffer is; the two are the same type, and FUSE's own
    buffers are passed straight in as one. *)
type buffer = Bigstringaf.t

(** Zero [len] bytes of [buf] from [pos]: a hole a read did not cover. *)
val zero : buffer -> pos:int -> len:int -> unit

val read : string -> buffer -> offset:int64 -> int Lwt.t
val write : string -> buffer -> offset:int64 -> int Lwt.t

(** [pread fd buf ~file_offset pos len] fills [len] bytes of [buf] from [pos],
    reading [fd] at [file_offset]. The offset travels with the call, so several
    ranges of one file can be moved concurrently through one descriptor. *)
val pread :
  Lwt_unix.file_descr -> buffer -> file_offset:int -> int -> int -> int Lwt.t

val pwrite :
  Lwt_unix.file_descr -> buffer -> file_offset:int -> int -> int -> int Lwt.t
