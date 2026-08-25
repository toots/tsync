(* Taking up a record someone else wrote.

   [post] writes the job and queues it. A caller that owns the durable half
   itself -- the file operations, which write their own journal records -- needs
   only the second half, and needs it to be safe to offer the same record twice:
   a signal can be repeated, and a record queued twice is a job run twice. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "queue-adopt"

module Q = Durable_queue_lwt.Make (struct
  type t = string

  let to_string s = s
  let of_string s = Some s
end)

let log_dir = Filename.concat root "owed"
let log = Q.Records.create ~dir:log_dir

(* Nothing drains: what is queued stays queued, so the counts are readable. *)
let queue =
  Q.ordered ~name:"adopt" ~classify:Retry.classify ~log
    ~poison:Durable_queue_lwt.Drop
    ~run:(fun _ -> fst (Lwt.wait ()))
    ()

let () =
  Lwt_main.run
    (case "a record already written";
     let* () = Q.Records.write log ~id:"one" "a" in
     let* () = Q.adopt queue ~id:"one" "a" in
     check "is queued" (Q.owed queue = 1);

     case "offered a second time";
     let* () = Q.adopt queue ~id:"one" "a" in
     check "is not queued twice" (Q.owed queue = 1);

     case "a second record";
     let* () = Q.Records.write log ~id:"two" "b" in
     let* () = Q.adopt queue ~id:"two" "b" in
     check "is queued beside it" (Q.owed queue = 2);

     (* [adopt] writes nothing: the caller owns that half. *)
     case "the log";
     let+ names = Io_lwt.Fs.readdir_list log_dir in
     check "holds exactly what was written" (List.length names = 2);
     report ~expected:4 ())
