(* Rt.configure: bounds are taken before the scheduler starts, refused after,
   and a call that sets nothing is never refused. *)

open Tsync_core

let attempt what f =
  match f () with
    | () -> Printf.printf "%s: taken\n" what
    | exception Invalid_argument _ -> Printf.printf "%s: refused\n" what

let () =
  attempt "bounds before the first fiber" (fun () ->
      Rt.configure ~workers:1 ~max_blocking:4 ());
  Printf.printf "first fiber answers %d\n" (Rt.run_sync (fun () -> 42));
  attempt "bounds after it" (fun () -> Rt.configure ~workers:2 ());
  attempt "no bounds after it" (fun () -> Rt.configure ())
