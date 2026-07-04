(* Validate the whole-file chunk hasher against the independent single-hash path.
   [Xxhash.hash_chunks_bigarray] loops chunks in C under one runtime-lock release;
   [Xxhash.hash_hex] hashes one string. Both call XXH3_64bits_withSeed on the same
   bytes, so per chunk they must agree — this pins the C loop's chunk indexing,
   last-partial-chunk sizing, and hex formatting (and thus chunk-key stability). *)

let make_buf total =
  let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout total in
  for i = 0 to total - 1 do
    buf.{i} <- Char.chr (((i * 31) + 7) land 0xff)
  done;
  buf

let slice_string total off len =
  String.init len (fun j -> Char.chr ((((off + j) * 31) + 7) land 0xff))

let check ~chunk_size ~total =
  let buf = make_buf total in
  let hashes = Xxhash.hash_chunks_bigarray buf ~length:total ~chunk_size in
  let expect_chunks =
    if total = 0 then 1 else (total + chunk_size - 1) / chunk_size
  in
  assert (Array.length hashes = expect_chunks);
  Array.iteri
    (fun i (h1, h2) ->
      let off = i * chunk_size in
      let len = min chunk_size (total - off) in
      let s = slice_string total off len in
      assert (h1 = Xxhash.hash_hex s 0);
      assert (h2 = Xxhash.hash_hex s 1))
    hashes

let () =
  check ~chunk_size:1000 ~total:2600;
  (* 3 chunks, last partial *)
  check ~chunk_size:1000 ~total:2000;
  (* exact boundary, 2 full chunks *)
  check ~chunk_size:1000 ~total:500;
  (* single short chunk *)
  check ~chunk_size:1000 ~total:0;
  (* empty file -> one empty chunk *)
  print_endline "ok"
