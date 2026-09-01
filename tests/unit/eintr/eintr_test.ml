(* What a signal does to a file operation, and why [Stdlib] is not enough.

   [Sys.set_signal] installs handlers without [SA_RESTART], and [Lwt_main.run]
   installs one for [SIGCHLD] whether or not anything waits on a child. So from
   the first turn of the loop every blocking syscall in the process can be
   interrupted -- and was: a start-up subprocess reaped while [open_in] was
   reading [client-uuid] took the daemon's event loop down with a [Sys_error].

   Both halves below are the point of the shim. The [Sys_error] spelling is why
   a [Unix_error (EINTR, _, _)] handler over the call site would not have caught
   it, and [file_exists] answering [false] is why that call site would not even
   have raised: it would have decided the uuid file was missing and written a new
   identity over the live one.

   This file is compiled with [-open Tsync_stdlib], like the libraries it stands
   for, so the names below are the shadowed ones and [Stdlib.] is what reaches
   past them. *)

open Check

let raising exn =
  let attempts = ref 0 in
  let f () =
    incr attempts;
    if !attempts < 3 then raise (exn ()) else "done"
  in
  (attempts, f)

let () =
  case "an interruption is retried, in either spelling";
  List.iter
    (fun (name, exn) ->
      let attempts, f = raising exn in
      let got = Eintr.retry f in
      Printf.printf "  %-34s %s after %d attempt(s)\n" name got !attempts)
    [
      ( "Unix_error (EINTR, _, _)",
        fun () -> Unix.Unix_error (Unix.EINTR, "open", "f") );
      (* What [runtime/sys.c] raises instead. The message is [strerror]'s, so it
         is the same text [Unix.error_message] gives, and nothing else in the
         exception identifies it. *)
      ( "Sys_error \"...: <EINTR>\"",
        fun () -> Sys_error ("f: " ^ Unix.error_message Unix.EINTR) );
    ];

  case "anything else is the caller's";
  List.iter
    (fun (name, exn) ->
      Printf.printf "  %-34s %s\n" name
        (match Eintr.retry (fun () -> raise (exn ())) with
          | (_ : string) -> "swallowed"
          | exception e -> Printexc.to_string e))
    [
      ( "Unix_error (EACCES, _, _)",
        fun () -> Unix.Unix_error (Unix.EACCES, "open", "f") );
      ( "Sys_error, another errno",
        fun () -> Sys_error "f: No such file or directory" );
      (* Mentioned, but not as the suffix: someone else's message. *)
      ( "Sys_error, EINTR not the suffix",
        fun () -> Sys_error (Unix.error_message Unix.EINTR ^ ": f") );
    ];

  case "the shadowed Sys keeps Stdlib's answers";
  let dir = Filename.temp_dir "eintr" "" in
  let path = Filename.concat dir "f" in
  let show label p =
    Printf.printf "  %-34s %b (Stdlib: %b)\n" label (Sys.file_exists p)
      (Stdlib.Sys.file_exists p)
  in
  show "missing" path;
  close_out (open_out path);
  show "a file" path;
  show "a directory" dir;
  Unix.symlink (Filename.concat dir "gone") (Filename.concat dir "dangling");
  show "a dangling symlink" (Filename.concat dir "dangling");
  Unix.unlink (Filename.concat dir "dangling");
  Sys.remove path;
  Unix.rmdir dir
