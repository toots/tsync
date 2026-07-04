(* Known-answer test for [Xxhash.hash_hex]: chunk keys are built from these hex
   strings, so their values (XXH3-64, seeds 0 and 1, 16-char lowercase hex) must
   never change — a change here breaks dedup against already-uploaded chunks.
   The expected output is pinned in hash.expected. *)

let pattern i = Char.chr (((i * 31) + 7) land 0xff)

let () =
  let inputs =
    [
      ("empty", "");
      ("hello", "hello world");
      ("pattern-2600", String.init 2600 pattern);
      ("pattern-8MiB", String.init (8 * 1024 * 1024) pattern);
    ]
  in
  List.iter
    (fun (name, data) ->
      Printf.printf "%s: %s %s\n" name (Xxhash.hash_hex data 0)
        (Xxhash.hash_hex data 1))
    inputs;
  (* XXH3-64 of the empty string is a published reference value. *)
  assert (Xxhash.hash_hex "" 0 = "2d06800538d394c2");
  print_endline "ok"
