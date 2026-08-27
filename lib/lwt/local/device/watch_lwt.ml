(* The waiting half. The pure library hands over a descriptor and never blocks
   on one, so this is the only place that names a scheduler. *)

open Lwt.Syntax

type t = { watcher : Watch.t; readable : Lwt_unix.file_descr }

(* Wrapped once rather than per wait: the wrapper carries the engine's own state
   for the descriptor, and a fresh one each time registers a fresh set of it. *)
let open_dir dir =
  Option.map
    (fun watcher ->
      {
        watcher;
        readable =
          Lwt_unix.of_unix_file_descr ~blocking:false (Watch.fd watcher);
      })
    (Watch.open_dir dir)

(* Drained after the wait, so what arrives between the two is what makes the
   next wait return at once rather than something nobody hears about. *)
let wait t =
  let* () = Lwt_unix.wait_read t.readable in
  Watch.drain t.watcher;
  Lwt.return_unit

let close t = Watch.close t.watcher
