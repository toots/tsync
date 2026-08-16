(* What a mapped chunk promises, asserted rather than described.

   Chunk bodies are mapped instead of read on the strength of a handful of
   claims about [MAP_PRIVATE] and about [Unix.map_file]'s stub, and every one of
   them is a property of the platform rather than of code in this repository:
   nothing here would fail if a kernel or a runtime changed its mind. So each is
   exercised directly, including the two that say what mapping does {i not}
   give — those are the ones a later reader is most likely to assume away.

   The count printed at the end is what stops this file from passing while
   testing nothing: a case that stops running takes the total with it. *)

open Check

let root = Filename.temp_dir "tsync-chunk" ""
let path name = Filename.concat root name

let write_file p data =
  let oc = open_out_bin p in
  output_string oc data;
  close_out oc

let read_file p =
  let ic = open_in_bin p in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

(* Published the way a cache body is: written elsewhere, renamed over. *)
let publish p data =
  let tmp = p ^ ".tmp" in
  write_file tmp data;
  Sys.rename tmp p

let body = String.init 8192 (fun i -> Char.chr (((i * 31) + 7) land 0xff))

let () =
  (* Round trips, and the empty chunk that an empty file still yields. *)
  check "of_string/to_string" (Chunk.to_string (Chunk.of_string body) = body);
  check "length" (Chunk.length (Chunk.of_string body) = String.length body);
  check "empty"
    (Chunk.length Chunk.empty = 0 && Chunk.to_string Chunk.empty = "");
  (* A zero-length mapping is [addr = NULL] in the stub, so it is special-cased
     rather than mapped. *)
  let p = path "empty" in
  write_file p "";
  check "map empty" (Chunk.length (Chunk.map_file ~path:p ~offset:0 ~len:0) = 0);

  (* 1. A mapping outlives the name it was made from. This is what lets the cache
     cap delete a body under a reader. *)
  let p = path "unlinked" in
  write_file p body;
  let c = Chunk.map_file ~path:p ~offset:0 ~len:(String.length body) in
  Sys.remove p;
  check "survives unlink" (Chunk.to_string c = body);

  (* 2. A mapping is unaffected by the path being republished, the rename giving
     the name a different inode. This is the invariant that makes it safe to map
     a cache body at all. *)
  let p = path "republished" in
  write_file p body;
  let c = Chunk.map_file ~path:p ~offset:0 ~len:(String.length body) in
  publish p (String.make (String.length body) 'z');
  check "survives republish" (Chunk.to_string c = body);

  (* 3. A file too short for the mapping is an error, and — the part worth
     asserting — the file on disk is not grown to fit. [Unix.map_file] grows one
     that cannot cover the mapping; the read-only descriptor is what turns that
     into a failure. *)
  let p = path "short" in
  write_file p "abc";
  let raised =
    match Chunk.map_file ~path:p ~offset:0 ~len:4096 with
      | _ -> false
      | exception _ -> true
  in
  check "short file raises" raised;
  check "short file not grown" (String.length (read_file p) = 3);

  (* 4. MAP_PRIVATE: writing through a view does not reach the file. *)
  let p = path "private" in
  write_file p body;
  let c = Chunk.map_file ~path:p ~offset:0 ~len:(String.length body) in
  Bigstringaf.set (Chunk.buffer c) 0 'Z';
  check "write does not reach file" (read_file p = body);

  (* 7. Mapping at an offset, which is how a group member is addressed and which
     the stub has to align for us. *)
  let p = path "offset" in
  write_file p body;
  let c = Chunk.map_file ~path:p ~offset:100 ~len:50 in
  check "unaligned offset" (Chunk.to_string c = String.sub body 100 50);

  (* 9. Hashing reaches the bytes wherever they are. *)
  let p = path "hashed" in
  write_file p body;
  let c = Chunk.map_file ~path:p ~offset:0 ~len:(String.length body) in
  check "hash matches string"
    (Chunk.hash_hex c 0 = Xxhash.hash_hex body 0
    && Chunk.hash_hex (Chunk.of_string body) 1 = Xxhash.hash_hex body 1);

  (* 10. [create] registers its size with the collector where a mapping does not:
     the stub allocates a mapped bigarray with a declared cost of zero. The
     difference is the reason anonymous bytes need no bound of their own and
     mappings do. *)
  let extra f =
    let before = (Gc.quick_stat ()).Gc.minor_words in
    let kept = f () in
    let after = (Gc.quick_stat ()).Gc.minor_words in
    ignore (Sys.opaque_identity kept);
    after -. before
  in
  let p = path "accounted" in
  write_file p (String.make (4 * 1024 * 1024) 'a');
  let mapped =
    extra (fun () -> Chunk.map_file ~path:p ~offset:0 ~len:(4 * 1024 * 1024))
  in
  check "mapping is a small heap object" (mapped < 1000.);

  (* 12. Written back and read again. *)
  let p = path "written" in
  Lwt_main.run (Chunk.write_to ~path:p (Chunk.of_string body) ~offset:0);
  check "write_to" (read_file p = body);

  Printf.printf "checks: %d\n" (checks ());
  (* A suite that stopped running its cases would otherwise report a clean pass. *)
  assert (checks () = 13)
