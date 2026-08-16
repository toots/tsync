(* Who may run a record another process wrote.

   A record is on disk before the work it names has run, so a daemon reading
   another process's log takes jobs that process is about to run itself — and a
   daemon that never reads it strands whatever a command left behind when its
   settle timeout expired. Both are asserted here, against a real second process
   rather than a stand-in, because what separates the two cases is a lock the
   kernel drops only when its holder dies. *)

open Lwt.Syntax

module J = struct
  type t = string

  let to_string s = s
  let of_string s = Some s
end

module Q = Durable_queue.Make (J)

(* The snapshot carries the verdict, so everything that decides one is a line on
   stdout: a status the rule reads instead would fail the run before the diff,
   with whatever it was about on the stderr the rule discards. *)
(* [Check.report] is deliberately not called: the exit status must stay zero so
   the diff is what fails, carrying what it was about. *)
open Check

(* Waits for the state, not for a duration: a fixed sleep is a race a loaded
   machine loses, and the snapshot then differs for reasons that have nothing to
   do with what is being asserted. *)
let await ?(timeout = 10.) cond =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    if cond () then Lwt.return_true
    else if Unix.gettimeofday () > deadline then Lwt.return_false
    else
      let* () = Lwt_unix.sleep 0.01 in
      loop ()
  in
  loop ()

let held_marker dir = Filename.concat dir ".held"

(* Claims [dir] the way a one-shot command does and stays alive holding it. *)
let hold dir =
  let log = Q.Records.create ~dir in
  let q =
    Q.ordered ~name:"holder" ~log ~poison:Durable_queue.Drop
      ~run:(fun _ -> Lwt.return_unit)
      ()
  in
  Q.start ~recover:false q;
  let oc = open_out (held_marker dir) in
  close_out oc;
  Lwt_main.run (Lwt_unix.sleep 300.)

let planted = ["alpha"; "beta"; "gamma"]
let held = ["delta"; "epsilon"; "zeta"]

let plant dir ~first jobs =
  let log = Q.Records.create ~dir in
  Lwt_list.iteri_s
    (fun i job ->
      let n = first + i in
      Q.Records.write log ~id:(Printf.sprintf "%020d-%08d-1" n n) job)
    jobs

let run ~dir ~kill_child () =
  let ran = ref [] in
  (* A job that does not finish keeps its record on disk, which is the only
     state in which reading the log twice can enqueue it twice. *)
  let gate, open_gate = Lwt.wait () in
  let holding = ref false in
  let* () = plant dir ~first:1 planted in
  (* The child announces its claim by creating a file, so what follows tests
     against a lock known to be held rather than against a race it usually
     wins. *)
  let* announced = await (fun () -> Sys.file_exists (held_marker dir)) in
  check "the holder announced its claim" announced;
  let log = Q.Records.create ~dir in
  let q =
    Q.ordered ~name:"taker" ~log ~poison:Durable_queue.Drop
      ~run:(fun job ->
        ran := !ran @ [job];
        if !holding then gate else Lwt.return_unit)
      ()
  in
  Q.start ~recover:true q;
  let* () = Durable_queue.settle_all ~timeout:2. () in
  check "a claimed log is left to the process that claimed it" (!ran = []);
  let* records = Q.Records.list log in
  check "and the records are still there to be taken"
    (List.length records = List.length planted);
  kill_child ();
  let* () = Durable_queue.rescan_all () in
  let* () = Durable_queue.settle_all ~timeout:5. () in
  check "an unclaimed log is taken over" (!ran = planted);
  let* records = Q.Records.list log in
  check "a job that ran leaves no record" (records = []);
  holding := true;
  ran := [];
  let* () = plant dir ~first:4 held in
  let* () = Durable_queue.rescan_all () in
  let* started = await (fun () -> !ran = [List.hd held]) in
  check "a held job keeps its record" started;
  let* () = Durable_queue.rescan_all () in
  Lwt.wakeup open_gate ();
  let* () = Durable_queue.settle_all ~timeout:5. () in
  check "reading the log while it is being worked runs nothing twice"
    (!ran = held);
  let+ records = Q.Records.list log in
  check "and leaves nothing owed" (records = [])

let () =
  Printexc.record_backtrace true;
  match Array.to_list Sys.argv with
    | _ :: "hold" :: dir :: _ -> hold dir
    | _ ->
        let root =
          Filename.concat
            (Filename.get_temp_dir_name ())
            (Printf.sprintf "queue-claim-%d" (Unix.getpid ()))
        in
        let dir = Filename.concat root "log" in
        let child =
          Unix.create_process Sys.executable_name
            [| Sys.executable_name; "hold"; dir |]
            Unix.stdin Unix.stdout Unix.stderr
        in
        let reaped = ref false in
        let kill_child () =
          if not !reaped then begin
            reaped := true;
            (try Unix.kill child Sys.sigkill with _ -> ());
            (* Reaping is best effort: whether this or a signal handler
               somewhere gets there first, the child is gone either way. *)
            try ignore (Unix.waitpid [] child) with _ -> ()
          end
        in
        (try
           Fun.protect ~finally:kill_child (fun () ->
               Lwt_main.run (run ~dir ~kill_child ()))
         with exn ->
           Printf.printf "unexpected error: %s\n%s%!" (Printexc.to_string exn)
             (Printexc.get_backtrace ()));
        Scratch.cleanup root
