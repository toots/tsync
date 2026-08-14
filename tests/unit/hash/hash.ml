(* Known-answer test for [Xxhash.hash_hex] and for the chunk key composed from
   it. Chunk keys are built from these hex strings (XXH3-64, seeds 0 and 1,
   16-char lowercase), so a change here breaks dedup against already-uploaded
   chunks.

   The key column is read back by [lambda/test_chunk_key.py], which recomputes it
   in Python: the bucket's verifier hashes stored chunks in a second
   implementation, and if the two ever disagree it does not merely miss
   corruption, it files every chunk in the store as corrupt. One golden file,
   checked from both sides, so there is no third copy to drift.

   Sizes are XXH3's own branch boundaries (<=16, <=128, <=240, >240) plus 1 MiB,
   which is where the AWS store splits an object into read slices and so where a
   streamed hash would diverge from a one-shot one if the two were not the same
   function. *)

let pattern i = Char.chr (((i * 31) + 7) land 0xff)
let sizes = [0; 1; 16; 17; 128; 129; 240; 241; 2600; 1048576; 1048577; 8388608]

let () =
  let inputs =
    ("empty", "") :: ("hello", "hello world")
    :: List.map
         (fun n -> (Printf.sprintf "pattern-%d" n, String.init n pattern))
         sizes
  in
  List.iter
    (fun (name, data) ->
      Printf.printf "%s: %s %s %s\n" name (Xxhash.hash_hex data 0)
        (Xxhash.hash_hex data 1)
        (Chunk_layout.key_of_body data))
    inputs;
  (* XXH3-64 of the empty string is a published reference value. *)
  assert (Xxhash.hash_hex "" 0 = "2d06800538d394c2");
  (* The key really is the two digests joined, which is what the Python side
     reimplements rather than the digests themselves. *)
  List.iter
    (fun (_, data) ->
      assert (
        Chunk_layout.key_of_body data
        = Xxhash.hash_hex data 0 ^ "-" ^ Xxhash.hash_hex data 1))
    inputs;
  (* Streaming API: single update must match one-shot hash_hex. *)
  List.iter
    (fun (_, data) ->
      List.iter
        (fun seed ->
          let s = Xxhash.create seed in
          Xxhash.update s data;
          assert (Xxhash.digest_hex s = Xxhash.hash_hex data seed))
        [0; 1])
    inputs;
  (* Streaming API: split update must match one-shot hash_hex. A chunk arrives at
     the verifier in slices, so this is the property the marker rests on. *)
  List.iter
    (fun (_, data) ->
      List.iter
        (fun at ->
          if at <= String.length data then (
            let s = Xxhash.create 0 in
            Xxhash.update s (String.sub data 0 at);
            Xxhash.update s (String.sub data at (String.length data - at));
            assert (Xxhash.digest_hex s = Xxhash.hash_hex data 0)))
        [1; 16; 240; 1048576])
    inputs;
  print_endline "ok"
