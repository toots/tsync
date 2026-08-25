(* A server that stopped answering while its CPU is idle shows up here as
   watched descriptors that never drain. *)
type t = {
  readable_fds : int;
  writable_fds : int;
  timers : int;
  pool_size : int;
}

let stats () =
  {
    readable_fds = Lwt_engine.readable_count ();
    writable_fds = Lwt_engine.writable_count ();
    timers = Lwt_engine.timer_count ();
    pool_size = Lwt_unix.pool_size ();
  }
