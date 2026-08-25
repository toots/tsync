(* MEMTRACE names a directory, one file per process inside it: a daemon's
   frontends and a command are several processes, and two of them inheriting one
   trace fd drop about half their samples into a file that still reads clean,
   neither saying which process allocated. Sampling defaults to 1e-6;
   MEMTRACE_RATE raises it. *)
let trace_process ~name =
  match Sys.getenv_opt "MEMTRACE" with
    | None | Some "" -> ()
    | Some dir ->
        if not (Sys.file_exists dir && Sys.is_directory dir) then
          failwith (Printf.sprintf "MEMTRACE=%s is not a directory" dir);
        let filename = Filename.concat dir (name ^ ".ctf") in
        Unix.putenv "MEMTRACE" filename;
        Memtrace.trace_if_requested ~context:name ();
        Log.info "memory trace: %s" filename

(* [Lwt_main.run] plus a drain: a command returns as soon as its work is posted
   and a deferred target fills in the background, so without this a short-lived
   command exits leaving copies for the daemon it may not be running alongside.

   [report] is a thunk calling {!Job_report_lwt.start}, run here so a long command
   reports for as long as it runs — the drain included, which is work a caller
   would otherwise see as a command that had finished. *)
let run ?report p =
  let open Lwt.Syntax in
  (* Named for the subcommand and the pid, so a folder imported one call at a
     time leaves a trace per run rather than overwriting the last. *)
  trace_process
    ~name:
      (Printf.sprintf "%s-%d"
         (if Array.length Sys.argv > 1 then Filename.basename Sys.argv.(1)
          else "tsync")
         (Unix.getpid ()));
  Lwt_main.run
    (Option.iter (fun start -> start ()) report;
     (* A command that raised still says so, since its process is about to go
        and nothing else will ever answer for it. *)
     let* r =
       Lwt.catch
         (fun () -> p)
         (fun exn ->
           let* () = Job_report_lwt.finish ~error:(Printexc.to_string exn) () in
           Lwt.fail exn)
     in
     let* () = Backend.drain () in
     let+ () = Job_report_lwt.finish () in
     r)
