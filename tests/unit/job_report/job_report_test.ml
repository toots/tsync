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

let failures = ref 0

let check name ok =
  if ok then Printf.printf "%s: ok\n%!" name
  else begin
    incr failures;
    Printf.printf "%s: FAILED\n%!" name
  end

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
    (Job_report.set_interval 0.1;

     (* No listener at all: the path does not exist. *)
     Job_report.start
       ~socket_path:(Filename.concat root "absent.sock")
       ~domain:"d" ~kind:"import"
       ~counters:(fun () -> [("files", 3)])
       ();
     let* () = Lwt_unix.sleep 0.45 in
     check "reporting to a socket nobody is listening on does not raise" true;
     let* () = Job_report.finish () in
     check "and finishing against it does not raise either" true;

     (* A listener that answers, so the payload can be inspected. *)
     let path = Filename.concat root "live.sock" in
     let seen = ref [] in
     let* () = stub_server ~path ~seen in
     Job_report.start ~socket_path:path ~domain:"d" ~kind:"import"
       ~target:"/media/files/stage"
       ~current:(fun () -> Some "big.mov")
       ~deferred:(fun () -> Some (207, 3, false))
       ~counters:(fun () -> [("files", 30433); ("failed", 0)])
       ();
     let* () = Lwt_unix.sleep 0.45 in
     let* () = Job_report.finish ~summary:[("files", 30434)] () in
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
     check "and a done report is sent last"
       (let final = Yojson.Safe.from_string (List.hd !seen) in
        Yojson.Safe.Util.member "state" final = `String "done");

     if !failures > 0 then exit 1;
     Lwt.return_unit)
