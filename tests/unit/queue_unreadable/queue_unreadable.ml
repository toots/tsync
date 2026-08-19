(* What a record nobody can parse costs the target it was owed to.

   The body is discarded — nothing can replay it, and leaving it would stall the
   queue at every start — so the write it named is lost for good and only a
   mirror puts it back. Patience does not fix that, which is what [degraded]
   means, so the assertion here is that dropping one raises the flag rather than
   leaving the target reported as merely behind. *)

open Lwt.Syntax
open Check

module J = struct
  type t = string

  let to_string s = s
  let of_string s = if s = "" then None else Some s
end

module Q = Durable_queue.Make (J)

let dir = Filename.concat (Filename.temp_dir "tsync-queue-unreadable" "") "log"

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

     case "the log reports what it could not read";
     let* records = Q.Records.list log in
     check "the readable records come back" (List.length records = 2);
     check "and the unreadable one is counted on the log"
       (Q.Records.dropped log = 1);
     check "which leaves nothing behind to stall the next start"
       (not (Sys.file_exists (Filename.concat dir "00000000000000000002-b")));

     case "a queue that resumed over one is degraded";
     let ran = ref [] in
     let q =
       Q.ordered ~name:"unreadable" ~log ~poison:Durable_queue.Drop
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
     report ~expected:5 ();
     Lwt.return_unit)
