(* What a job report must survive.

   The report is advisory: a command runs whether or not anything is listening,
   and the daemon being absent is the ordinary case rather than an error. So the
   property that matters is not that a report arrives — it is that failing to
   send one cannot reach the command. The reporting loop runs under [Lwt.async],
   whose default exception hook takes the process down, so an unswallowed
   [ECONNREFUSED] would kill an import for want of a listener.

   That is asserted by the test surviving: if the loop lets an exception out,
   this exits non-zero of its own accord. *)

open Lwt.Syntax
open Check

let root = Filename.temp_dir "tsync-job-report" ""

(* Accepts, reads one line, answers as the daemon does, and keeps what it saw. *)
let stub_server ~path ~seen =
  let sock = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let* () = Lwt_unix.bind sock (Unix.ADDR_UNIX path) in
  Lwt_unix.listen sock 8;
  let rec accept () =
    let* fd, _ = Lwt_unix.accept sock in
    let ic = Lwt_io.of_fd ~mode:Lwt_io.Input fd in
    let oc = Lwt_io.of_fd ~mode:Lwt_io.Output fd in
    let* line = Lwt_io.read_line_opt ic in
    (match line with Some l -> seen := l :: !seen | None -> ());
    let* () = Lwt_io.write_line oc {|{"ok":true}|} in
    let* () = Lwt_io.flush oc in
    let* () = Lwt_unix.close fd in
    accept ()
  in
  Lwt.async accept;
  Lwt.return_unit

let () =
  Lwt_main.run
    ((* No listener at all: the path does not exist. *)
     Job.Report.start ~interval:0.1
       ~socket_path:(Filename.concat root "absent.sock")
       ~domain:"d" ~kind:"import"
       ~counters:(fun () -> [("files", 3)])
       ();
     let* () = Lwt_unix.sleep 0.45 in
     check "reporting to a socket nobody is listening on does not raise" true;
     let* () = Job.Report.finish () in
     check "and finishing against it does not raise either" true;

     (* A listener that answers, so the payload can be inspected. *)
     let path = Filename.concat root "live.sock" in
     let seen = ref [] in
     let* () = stub_server ~path ~seen in
     Job.Report.start ~socket_path:path ~domain:"d" ~kind:"import" ~interval:0.1
       ~target:"/media/files/stage"
       ~current:(fun () -> Some "big.mov")
       ~deferred:(fun () -> Some (207, 3, false))
       ~counters:(fun () -> [("files", 30433); ("failed", 0)])
       ();
     (* A run whose plan is 1000 bytes: one entry of 400 already in the domain,
        one of 600 half sent. *)
     Job.Progress.plan ~bytes:1000L;
     Job.Progress.start_entry ~size:400L;
     Job.Progress.finish_entry `Skipped;
     Job.Progress.start_entry ~size:600L;
     Job.Progress.advance ~bytes:300L ~sent:true;
     let* () = Lwt_unix.sleep 0.45 in
     let* () = Job.Report.finish () in
     check "a listening daemon receives reports" (!seen <> []);

     let last = List.hd (List.rev !seen) in
     let j = Yojson.Safe.from_string last in
     let mem k = Yojson.Safe.Util.member k j in
     check "the payload is a report action" (mem "action" = `String "report");
     check "it names the job" (mem "kind" = `String "import");
     check "it carries the pid" (mem "pid" = `Int (Unix.getpid ()));
     check "it carries what the command is working on"
       (mem "current" = `String "big.mov");
     check "it carries the deferred queue"
       (Yojson.Safe.Util.member "queued" (mem "deferred") = `Int 207);
     check "it carries the command's own counters"
       (mem "counters"
       = `List
           [
             `List [`String "files"; `Int 30433];
             `List [`String "failed"; `Int 0];
           ]);
     check "it carries memory the command never supplied"
       (Yojson.Safe.Util.member "rssBytes" (mem "memory") <> `Null);
     let progress k = Yojson.Safe.Util.member k (mem "progress") in
     check "it carries the bytes the command recorded"
       (progress "bytesTotal" = `Int 1000
       && progress "bytesSkipped" = `Int 400
       && progress "bytesDone" = `Int 300);
     (* Counting only finished entries would report nothing done for as long as
        the entry in flight takes, which on a large file is hours. *)
     check "the entry in flight counts toward what is done and what is left"
       (progress "bytesHandled" = `Int 700
       && progress "bytesRemaining" = `Int 300);
     check "and the entry in flight says how far into it the run is"
       (Yojson.Safe.Util.member "bytesDone" (progress "current") = `Int 300
       && Yojson.Safe.Util.member "bytesTotal" (progress "current") = `Int 600);
     check "and a done report is sent last"
       (let final = Yojson.Safe.from_string (List.hd !seen) in
        Yojson.Safe.Util.member "state" final = `String "done");

     (* Counted, so a suite that stopped exercising anything fails rather than
        passing quietly. *)
     report ~expected:14 ();
     Lwt.return_unit)
