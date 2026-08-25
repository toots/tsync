(* Which spool files a starting run is allowed to delete.

   A run reaps the directory on startup so a killed predecessor's spool does not
   sit there forever. The sweep is destructive against anything it misjudges: a
   second import on the same machine has its own spool open in that directory,
   and deleting it loses every op the running import has spooled and crashes it
   at seal, on a stat of a path with no name left on it. That happened.

   So what is pinned here is the negative: a live process's spool survives. *)

open Lwt.Syntax

let dir = Scratch.dir "spool-reap"

(* A pid that has certainly exited: forked, waited for, and never reused within
   this test. *)
let dead_pid () =
  match Unix.fork () with
    | 0 -> Unix._exit 0
    | pid ->
        ignore (Unix.waitpid [] pid);
        pid

let plant name =
  let oc = open_out_bin (Filename.concat dir name) in
  output_string oc "ops";
  close_out oc;
  name

(* Names carry the pid that made them, so the snapshot says what each file is
   rather than what it is called. *)
let describe ~mine ~theirs name =
  if name = mine then "this run's open spool"
  else if name = theirs then "a dead run's spool"
  else "a user's file"

let listing ~mine ~theirs =
  List.sort compare
    (List.map (describe ~mine ~theirs) (Array.to_list (Sys.readdir dir)))

let () =
  Lwt_main.run
    (let dead = dead_pid () in
     let* mine = Spool_lwt.create ~dir ~name:"journal" in
     let mine = Filename.basename (Spool_lwt.path mine) in
     let theirs = plant (Printf.sprintf ".tsync-tmp-%d-1.tmp" dead) in
     let user = plant ".syncthing.Big.Buck.Bunny.mkv.tmp" in

     Printf.printf "\n=== before the sweep\n";
     List.iter (Printf.printf "  %s\n") (listing ~mine ~theirs);

     let+ () = Spool_lwt.reap ~dir in
     Printf.printf "\n=== after the sweep\n";
     List.iter (Printf.printf "  %s\n") (listing ~mine ~theirs);

     Printf.printf "\n=== what became of each\n";
     let fate name =
       if Sys.file_exists (Filename.concat dir name) then "kept" else "reaped"
     in
     List.iter
       (fun name ->
         Printf.printf "  %-24s %s\n" (describe ~mine ~theirs name) (fate name))
       [mine; theirs; user])
