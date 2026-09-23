(* The two ways a queue is stopped. A command finishing still runs what it
   queued: that is what its stop is for. A process asked to stop takes no more
   work, lets what is running give way, and leaves the rest on disk, where its
   next start finds every job still owed. *)

open Lwt.Syntax
open Check

module J = struct
  type t = string

  let to_string s = s
  let of_string s = Some s
end

module Q = Durable_queue_lwt.Make (J)
module Nap = Shutdown.Sleep (Io_lwt.Core) (Io_lwt.Clock)

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-queue-stop-%d" (Unix.getpid ()))

let on_disk dir =
  match Sys.readdir dir with
    | names -> Array.length names
    | exception Sys_error _ -> 0

let queue ~dir ~run =
  Q.ordered ~name:"test" ~classify:Retry.classify ~log:(Q.Records.create ~dir)
    ~poison:Durable_queue_lwt.Drop
    ~run:(fun ~id:_ job -> run job)
    ()

let post_all q jobs = Lwt_list.iter_s (fun j -> Q.post q j) jobs
let jobs = List.init 6 (Printf.sprintf "job%d")

(* Within [seconds], or false. *)
let within seconds p =
  Lwt.pick
    [
      Lwt.map (fun () -> true) p;
      Lwt.map (fun () -> false) (Lwt_unix.sleep seconds);
    ]

let () =
  Lwt_main.run
    (case "a command's stop runs what it queued";
     let dir = Filename.concat root "command" in
     let ran = ref [] in
     let q =
       queue ~dir ~run:(fun job ->
           let+ () = Lwt_unix.sleep 0.01 in
           ran := job :: !ran)
     in
     Q.start q;
     let* () = post_all q jobs in
     let* () = Q.stop q in
     check "every job ran" (List.length !ran = 6);
     check "and none is owed" (on_disk dir = 0);

     case "a process stop takes no more, and leaves them on disk";
     let dir = Filename.concat root "process" in
     let started = ref 0 in
     (* Each job waits on the link as a slow upload would, and gives way to
        the stop as the drivers' ladders do. *)
     let q =
       queue ~dir ~run:(fun _ ->
           incr started;
           let* r = Nap.sleep 30. in
           match r with
             | `Slept -> Lwt.return_unit
             | `Stopping -> Lwt.fail Shutdown.Stopping)
     in
     Q.start q;
     let* () = post_all q jobs in
     let* () = Lwt.pause () in
     Shutdown.request ();
     let* quick = within 2. (Q.stop q) in
     check "the stop returns at once" quick;
     check "having begun only the job that was running" (!started = 1);
     check "every job still owed on disk" (on_disk dir = 6);
     let* settled = within 1. (Durable_queue_lwt.settle_all ()) in
     check "nothing is waited out" settled;

     case "the next start runs them all";
     Shutdown.reset ();
     Durable_queue_lwt.release dir;
     let ran = ref 0 in
     let q =
       queue ~dir ~run:(fun _ ->
           incr ran;
           Lwt.return_unit)
     in
     Q.start ~recover:true q;
     let* () = Q.stop q in
     check "six run" (!ran = 6);
     check "none owed" (on_disk dir = 0);

     report ~expected:8 ();
     Lwt.return_unit)
