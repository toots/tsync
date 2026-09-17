(* An ordered queue publishes in the order recorded however its jobs fail: what
   it carries are renames and removals, where a later one run first names
   something that is not there yet. *)

open Lwt.Syntax
open Check

module J = struct
  type t = string

  let to_string s = s
  let of_string s = if s = "" then None else Some s
end

module Q = Durable_queue_lwt.Make (J)

let dir = Filename.concat (Scratch.dir "queue-order") "log"

let until ready =
  let rec go tries =
    if ready () || tries = 0 then Lwt.return_unit
    else
      let* () = Lwt_unix.sleep 0.02 in
      go (tries - 1)
  in
  go 500

let () =
  Lwt_main.run
    (let log = Q.Records.create ~dir in
     let* () = Q.Records.write log ~id:"00000000000000000001-a" "first" in
     let* () = Q.Records.write log ~id:"00000000000000000002-b" "second" in
     let* () = Q.Records.write log ~id:"00000000000000000003-c" "third" in
     let ran = ref [] in
     let refusals = ref 2 in
     let tries_at_second = ref 0 in
     let q =
       Q.ordered ~name:"order" ~classify:Retry.classify ~log
         ~poison:Durable_queue_lwt.Stop
         ~run:(fun ~id job ->
           if job = "first" && !refusals > 0 then begin
             decr refusals;
             Lwt.fail (Retry.failed ~kind:Retry.Transient ~op:"run" "link down")
           end
           else if job = "second" then begin
             incr tries_at_second;
             Lwt.fail (Retry.failed ~kind:Retry.Permanent ~op:"run" id)
           end
           else begin
             ran := job :: !ran;
             Lwt.return_unit
           end)
         ()
     in
     Q.start ~recover:true q;
     let* () = until (fun () -> List.mem "third" !ran) in

     case "a job that fails and is retried is not overtaken";
     check "the jobs ran in the order recorded"
       ~why:(fun () -> String.concat ", " (List.rev !ran))
       (List.rev !ran = ["first"; "third"]);

     case "a job that cannot land steps aside and can be handed back";
     check "it is reported" (Q.stats q).Durable_queue_lwt.degraded;
     let* left = Q.Records.list log in
     check "its record stays" (List.map snd left = ["second"]);
     let* () = Q.adopt q ~id:"00000000000000000002-b" "second" in
     let* () = until (fun () -> !tries_at_second = 2) in
     check "and the queue tries it again" (!tries_at_second = 2);
     report ~expected:4 ();
     Lwt.return_unit)
