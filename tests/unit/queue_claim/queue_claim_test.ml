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

let failures = ref 0

let check name ok =
  if ok then Printf.printf "%s: ok\n%!" name
  else begin
    incr failures;
    Printf.printf "%s: FAILED\n%!" name
  end

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

(* The child announces its claim by creating a file, so the parent tests against
   a lock that is known to be held rather than against a race it usually wins. *)
let await_marker dir =
  let rec loop n =
    if Sys.file_exists (held_marker dir) then true
    else if n = 0 then false
    else (
      Unix.sleepf 0.05;
      loop (n - 1))
  in
  loop 200

let () =
  match Array.to_list Sys.argv with
    | _ :: "hold" :: dir :: _ -> hold dir
    | _ ->
        let dir =
          Filename.concat
            (Filename.get_temp_dir_name ())
            (Printf.sprintf "queue-claim-%d" (Unix.getpid ()))
        in
        let ran = ref [] in
        (* A job that does not finish keeps its record on disk, which is the only
           state in which reading the log twice can enqueue it twice. *)
        let gate, open_gate = Lwt.wait () in
        let hold = ref false in
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
            ignore (Unix.waitpid [] child)
          end
        in
        Fun.protect ~finally:kill_child (fun () ->
            Lwt_main.run
              (let* () = plant dir ~first:1 planted in
               check "the holder announced its claim" (await_marker dir);
               let log = Q.Records.create ~dir in
               let q =
                 Q.ordered ~name:"taker" ~log ~poison:Durable_queue.Drop
                   ~run:(fun job ->
                     ran := !ran @ [job];
                     if !hold then gate else Lwt.return_unit)
                   ()
               in
               Q.start ~recover:true q;
               let* () = Durable_queue.settle_all ~timeout:2. () in
               check "a claimed log is left to the process that claimed it"
                 (!ran = []);
               let* () =
                 let* records = Q.Records.list log in
                 check "and the records are still there to be taken"
                   (List.length records = List.length planted);
                 Lwt.return_unit
               in
               kill_child ();
               let* () = Durable_queue.rescan_all () in
               let* () = Durable_queue.settle_all ~timeout:5. () in
               check "an unclaimed log is taken over" (!ran = planted);
               let* records = Q.Records.list log in
               check "a job that ran leaves no record" (records = []);
               hold := true;
               ran := [];
               let* () = plant dir ~first:4 held in
               let* () = Durable_queue.rescan_all () in
               let* () = Lwt_unix.sleep 0.2 in
               check "a held job keeps its record" (!ran = [List.hd held]);
               let* () = Durable_queue.rescan_all () in
               Lwt.wakeup open_gate ();
               let* () = Durable_queue.settle_all ~timeout:5. () in
               check
                 "reading the log while it is being worked runs nothing twice"
                 (!ran = held);
               let+ records = Q.Records.list log in
               check "and leaves nothing owed" (records = [])));
        (try Sys.remove (held_marker dir) with _ -> ());
        (try Unix.rmdir dir with _ -> ());
        exit (if !failures = 0 then 0 else 1)
