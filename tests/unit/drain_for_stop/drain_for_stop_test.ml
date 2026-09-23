(* A stop's drain, bounded by the grace. One that finishes is waited for; one
   that does not is left running rather than cancelled, since a cancelled job
   fails as a job does and its queue records that failure against work that
   is only unfinished. *)

open Lwt.Syntax
open Check

let () =
  Shutdown.grace := 0.2;
  Lwt_main.run
    (case "a drain that finishes is waited for";
     let finished = ref false in
     let* () =
       Domain_engine.drain_for_stop
         [
           (fun () ->
             let+ () = Lwt_unix.sleep 0.05 in
             finished := true);
         ]
     in
     check "it finished" !finished;

     case "one that does not is left to the exit, not cancelled";
     let cancelled = ref false in
     let stuck () =
       let p, _ = Lwt.task () in
       Lwt.on_cancel p (fun () -> cancelled := true);
       p
     in
     let t0 = Unix.gettimeofday () in
     let* () = Domain_engine.drain_for_stop [stuck] in
     let took = Unix.gettimeofday () -. t0 in
     check "the stop moves on at the grace"
       ~why:(fun () -> Printf.sprintf "%.2fs" took)
       (took >= 0.2 && took < 1.);
     check "and the drain was not cancelled" (not !cancelled);

     report ~expected:3 ();
     Lwt.return_unit)
