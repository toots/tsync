open Tsync_core

(* Pitfall B-12.11: work that outlived the case would write under the root
   being removed, so a fiber that does not end on a stop fails the test. *)
let finish root =
  Stop.request ();
  let deadline = Unix.gettimeofday () +. Stop.grace in
  let rec wait () =
    match Rt.running () with
      | [] -> ()
      | left when Unix.gettimeofday () >= deadline ->
          prerr_endline
            ("still running after the stop: " ^ String.concat ", " left);
          exit 1
      | _ ->
          Unix.sleepf 0.01;
          wait ()
  in
  wait ();
  Fs.rm_rf root

(* Windows' chmod only sets the read-only attribute, so there an entry denies
   this user reading the data, or a directory's listing. *)
let icacls path change =
  let command =
    Printf.sprintf "icacls %s %s >NUL 2>&1" (Filename.quote path) change
  in
  if Sys.command command <> 0 then failwith ("icacls failed: " ^ command)

let set_unreadable path =
  if Sys.win32 then icacls path "/deny \"%USERNAME%:(RD)\""
  else Unix.chmod path 0

(* Windows restores the user-only list a private file is created with. *)
let set_readable ~perm path =
  if Sys.win32 then Fs.make_private path else Unix.chmod path perm
