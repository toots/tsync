(* Holds a main's collection run lock from another process until its standard
   input closes: record locks exclude processes, not fibers of one. With
   [wait], a lock held for a moment by the caller's own settles is waited for. *)

open Tsync_core
open Tsync_store

let hold () =
  print_endline "held";
  try
    while true do
      ignore (input_line stdin)
    done
  with End_of_file -> ()

let () =
  set_binary_mode_out stdout true;
  let root = Sys.argv.(1) and d = Domain_name.v Sys.argv.(2) in
  let wait = Array.length Sys.argv > 3 && Sys.argv.(3) = "wait" in
  let rec take tries =
    match Chunk_spaces.with_run_lock (Chunk_spaces.create root) d hold with
      | Ok () -> ()
      | Error `Busy when wait && tries > 0 ->
          Unix.sleepf 0.1;
          take (tries - 1)
      | Error `Busy -> print_endline "busy"
  in
  take 100
