(* Validate the whole-file chunk hasher against the independent single-hash path.
   [Xxhash.hash_file_chunks] opens+mmaps the file and loops chunks in C under one
   runtime-lock release, polling a cancel flag; [Xxhash.hash_hex] hashes one
   string. Both call XXH3_64bits_withSeed on the same bytes, so per chunk they
   must agree — this pins the C loop's chunk indexing, last-partial-chunk sizing,
   hex formatting (chunk-key stability), and the cancellation path. *)

let pattern i = Char.chr (((i * 31) + 7) land 0xff)

let write_pattern total =
  let path = Filename.temp_file "tsync-hash" ".bin" in
  let oc = open_out_bin path in
  output_string oc (String.init total pattern);
  close_out oc;
  path

let check ~chunk_size ~total =
  let path = write_pattern total in
  (match
     Xxhash.hash_file_chunks (Xxhash.hash_state_create path) ~chunk_size
   with
    | None -> assert false
    | Some (size, hashes) ->
        assert (size = total);
        let expect =
          if total = 0 then 1 else (total + chunk_size - 1) / chunk_size
        in
        assert (Array.length hashes = expect);
        Array.iteri
          (fun i (h1, h2) ->
            let off = i * chunk_size in
            let len = min chunk_size (total - off) in
            let s = String.init len (fun j -> pattern (off + j)) in
            assert (h1 = Xxhash.hash_hex s 0);
            assert (h2 = Xxhash.hash_hex s 1))
          hashes);
  Sys.remove path

let () =
  check ~chunk_size:1000 ~total:2600;
  (* 3 chunks, last partial *)
  check ~chunk_size:1000 ~total:2000;
  (* exact boundary, 2 full chunks *)
  check ~chunk_size:1000 ~total:500;
  (* single short chunk *)
  check ~chunk_size:1000 ~total:0;

  (* empty file -> one empty chunk *)

  (* A cancelled state stops the hash and returns None; reset re-enables it. *)
  let path = write_pattern 5000 in
  let state = Xxhash.hash_state_create path in
  Xxhash.hash_state_cancel state;
  assert (Xxhash.hash_file_chunks state ~chunk_size:1000 = None);
  Xxhash.hash_state_reset state;
  assert (Xxhash.hash_file_chunks state ~chunk_size:1000 <> None);
  Sys.remove path;

  print_endline "ok"
