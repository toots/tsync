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

let root = Scratch.dir "chunk"
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

(* Whether a clone is available is the filesystem's to say, so ask it once and
   assert against the answer: both claims below are then total, and the output
   says the same thing on btrfs, on APFS and on the ext4 that CI runs. *)
let clones =
  let src = path "probe" in
  write_file src "x";
  let ok =
    match try Device.clone ~src with _ -> None with
      | Some fd ->
          Unix.close fd;
          true
      | None -> false
  in
  Sys.remove src;
  (* Not stdout: the snapshot this file is diffed against must not vary by
     filesystem. *)
  Printf.eprintf "clones: %b\n" ok;
  ok

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

  (* 5. The clone is gone before [map_file] returns, so a directory tsync maps
     from never accumulates them and a kill mid-clone leaves nothing to reap. *)
  let p = path "no-litter" in
  write_file p body;
  ignore (Chunk.map_file ~path:p ~offset:0 ~len:(String.length body));
  check "clone left behind"
    (not (Array.exists Fs_util.is_temp_name (Sys.readdir root)));

  (* 6. The mapping is of a different inode from the file, which is the whole of
     what "frozen" means here and the only part of it this repository decides:
     the rest is the filesystem refusing to let a write reach those blocks. *)
  let p = path "snapshot" in
  write_file p body;
  let fd = Chunk.open_snapshot p in
  let mapped = (Unix.fstat fd).Unix.st_ino in
  Unix.close fd;
  check "mapped inode differs from the file exactly where it can be cloned"
    (mapped <> (Unix.stat p).Unix.st_ino = clones);

  (* 6b. Truncating the source under a mapping of it is [SIGBUS] on the page
     past the new end, which is a dead daemon mid-import rather than a short
     read, so the child surviving is the check. *)
  let p = path "truncated" in
  write_file p body;
  let c = Chunk.map_file ~path:p ~offset:0 ~len:(String.length body) in
  let survived =
    match Unix.fork () with
      | 0 ->
          Unix.truncate p 0;
          ignore (Sys.opaque_identity (Chunk.to_string c));
          exit 0
      | child -> snd (Unix.waitpid [] child) = Unix.WEXITED 0
  in
  (* Both directions matter: with a clone the child reads on, and without one
     the [SIGBUS] this exists to prevent is asserted to still be real. *)
  check "truncating the source is survivable exactly where it can be cloned"
    (survived = clones);

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

  (* Counted, so a case that stopped running takes the report with it, and
     reported, so a failure is an exit code rather than a line in a log. *)
  report ~expected:16 ()
