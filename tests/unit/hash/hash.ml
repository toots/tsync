(* Known answers for XXH3-64 and the chunk key built from it (01 §3.2). The rows
   are read back by [lambda/test_chunk_key.py], which recomputes them in Python:
   the bucket's verifier hashes stored chunks in a second implementation, and a
   disagreement files every chunk as corrupt (10 §3.1 item 4).

   Sizes are XXH3's branch boundaries (<=16, <=128, <=240, >240) plus 1 MiB,
   where a store reads an object in slices. *)

open Tsync_core

let pattern i = Char.chr (((i * 31) + 7) land 0xff)
let sizes = [0; 1; 16; 17; 128; 129; 240; 241; 2600; 1048576; 1048577; 8388608]
let hex seed data = Xxh.hex16 (Xxh.string ~seed data)

let () =
  let inputs =
    ("empty", "") :: ("hello", "hello world")
    :: List.map
         (fun n -> (Printf.sprintf "pattern-%d" n, String.init n pattern))
         sizes
  in
  List.iter
    (fun (name, data) ->
      Printf.printf "%s: %s %s %s\n" name (hex 0L data) (hex 1L data)
        (Chunk_key.to_string (Chunk_key.of_body data)))
    inputs;
  (* A published reference value. *)
  assert (hex 0L "" = "2d06800538d394c2");
  List.iter
    (fun (_, data) ->
      assert (
        Chunk_key.to_string (Chunk_key.of_body data)
        = hex 0L data ^ "-" ^ hex 1L data))
    inputs;
  print_endline "ok"
