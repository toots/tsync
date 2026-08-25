(** The Lwt event loop's load: descriptors watched, timers pending, and the
    blocking-syscall pool ceiling.

    Apart from {!Metrics} because it is the only figure there that asks a
    scheduler rather than the process. *)

type t = {
  readable_fds : int;
  writable_fds : int;
  timers : int;
  pool_size : int;
}

val stats : unit -> t
