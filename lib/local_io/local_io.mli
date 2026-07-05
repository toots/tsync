type buffer =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

val read : string -> buffer -> offset:int64 -> int Lwt.t
val write : string -> buffer -> offset:int64 -> int Lwt.t

(** Positioned variants for callers holding their own long-lived file
    descriptor, opened and closed by the caller. No open/seek/close per
    call, and safe under concurrent use of the same [fd] at different
    offsets: pread/pwrite don't touch a shared file position the way
    lseek+read/write would. *)
val pread : Lwt_unix.file_descr -> buffer -> offset:int64 -> int Lwt.t

val pwrite : Lwt_unix.file_descr -> buffer -> offset:int64 -> int Lwt.t
