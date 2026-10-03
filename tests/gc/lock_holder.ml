(* Holds a main's collection run lock from another process until its standard
   input closes: record locks exclude processes, not fibers of one. *)

open Tsync_core
open Tsync_store

let () =
  let root = Sys.argv.(1) and d = Domain_name.v Sys.argv.(2) in
  match
    Chunk_spaces.with_run_lock (Chunk_spaces.create root) d (fun () ->
        print_endline "held";
        try
          while true do
            ignore (input_line stdin)
          done
        with End_of_file -> ())
  with
    | Ok () -> ()
    | Error `Busy -> print_endline "busy"
