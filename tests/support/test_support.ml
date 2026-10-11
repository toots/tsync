open Tsync_core

(* Pitfall B-12.11: work that outlived the case would write under the root
   being removed, so a fiber that does not end on a stop fails the test. *)
let finish root =
  Stop.request ();
  let deadline = Unix.gettimeofday () +. Stop.grace in
  let rec wait () =
    match Rt.running () with
      | [] -> ()
      | left when Unix.gettimeofday () >= deadline ->
          prerr_endline
            ("still running after the stop: " ^ String.concat ", " left);
          exit 1
      | _ ->
          Unix.sleepf 0.01;
          wait ()
  in
  wait ();
  Fs.rm_rf root
