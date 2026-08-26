(* Handing a written record to whoever sends it.

   The record is written before this is reached, so nothing here decides whether
   the work survives -- a restart finds it either way. What it decides is when a
   file operation may return: with the work taken up, so that a delete arriving
   straight after a close finds the upload it has to cancel. *)

open Lwt.Syntax
open Check
module O = Wal_lwt.Owed

let () =
  Lwt_main.run
    (let t : string O.t = O.create () in
     let taken = ref [] in

     case "with nobody consuming";
     let* () = O.signal t "a" in
     check "a signal is not refused" (!taken = []);

     case "once a consumer is installed";
     O.consume t (fun x ->
         taken := !taken @ [x];
         Lwt.return_unit);
     let* () = O.signal t "b" in
     check "it is handed over" (!taken = ["b"]);
     check "and by the time the signal returns" (List.length !taken = 1);

     case "a second consumer";
     let other = ref [] in
     O.consume t (fun x ->
         other := !other @ [x];
         Lwt.return_unit);
     let* () = O.signal t "c" in
     check "displaces the first" (!taken = ["b"] && !other = ["c"]);

     case "going idle";
     O.idle t;
     let+ () = O.signal t "d" in
     check "leaves what follows written and untaken"
       (!taken = ["b"] && !other = ["c"]);
     report ~expected:5 ())
