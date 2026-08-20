(* What a record nobody can parse costs the target it was owed to.

   Which records a sweep drops and what it logs is {!queue_records}; this is the
   consequence, since the write a dropped record named is lost for good and only
   a mirror puts it back. Patience does not fix that, which is what [degraded]
   means, so what is asserted here is that dropping one raises the flag rather
   than leaving the target reported as merely behind. *)

open Lwt.Syntax
open Check

module J = struct
  type t = string

  let to_string s = s
  let of_string s = if s = "" then None else Some s
end

module Q = Durable_queue.Make (J)

let dir = Filename.concat (Filename.temp_dir "tsync-queue-degraded" "") "log"

(* Written past {!Records.write}, which would encode a body that parses. *)
let plant_unreadable id =
  let oc = open_out_bin (Filename.concat dir id) in
  close_out oc

let () =
  Lwt_main.run
    (let log = Q.Records.create ~dir in
     let* () = Q.Records.write log ~id:"00000000000000000001-a" "keep-me" in
     plant_unreadable "00000000000000000002-b";
     let* () = Q.Records.write log ~id:"00000000000000000003-c" "keep-me-too" in

     case "the log counts what it could not read";
     let* (_ : (string * string) list) = Q.Records.list log in
     check "a discarded record is counted on the log" (Q.Records.dropped log = 1);

     case "a queue that resumed over one is degraded";
     let ran = ref [] in
     let q =
       Q.ordered ~name:"degraded" ~log ~poison:Durable_queue.Drop
         ~run:(fun job ->
           ran := job :: !ran;
           Lwt.return_unit)
         ()
     in
     Q.start ~recover:true q;
     let* () = Durable_queue.settle_all ~timeout:5. () in
     check "the jobs it could read still ran"
       ~why:(fun () -> String.concat ", " !ran)
       (List.sort compare !ran = ["keep-me"; "keep-me-too"]);
     check "and the queue says a mirror is needed"
       (Q.stats q).Durable_queue.degraded;
     report ~expected:3 ();
     Lwt.return_unit)
