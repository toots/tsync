(* What an upload holds while it is running, per chunk of the file.

   The bound on chunk buffers says how many bodies are in memory at once and
   nothing about how many tasks are waiting for one: a task apiece is a promise,
   a closure and a pool queue cell, and a fan-out lays every one of them out
   before the first chunk is read. A terabyte at the default chunk size is a
   hundred and thirty thousand of each, and they outlive every buffer they are
   queueing for.

   So what is sampled is live words when the first chunk lands — the moment a
   task-per-chunk shape is holding the whole file's worth — divided by the
   chunks there are. The figure itself is machine-dependent and stays out of the
   snapshot; it reaches a reader through [~why], on failure, where it is worth
   having. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "upload-fanout"
let chunk_size = 8
let buffers = 2

(* Enough chunks that a task apiece is unmistakable against the fixed cost of
   opening the file and the store. *)
let chunks = 2000

let conf =
  Fixture.conf ~domain:"fanout" ~root ~chunk_size ~cache_chunk_size:chunk_size
    ~max_chunk_buffers:buffers ()

module C = (val conf : Conf.S)
module R = Remote.Make (C)

(* Seeded so no two chunks share content: a file of one repeated byte
   deduplicates to a single put and never fills the pool. *)
let source =
  let path = Filename.concat root "big.bin" in
  let oc = open_out_bin path in
  output_string oc
    (String.init (chunks * chunk_size) (fun i -> Char.chr (i * 7 mod 251)));
  close_out oc;
  path

let () =
  Lwt_main.run
    (case "an upload's tasks do not scale with the file";
     let live_at_first_chunk = ref 0 in
     let landed = ref 0 in
     let baseline = (Stdlib.Gc.stat ()).Stdlib.Gc.live_words in
     let* manifest =
       R.upload
         ~key:(C.domain_prefix ^ "big.bin")
         ~src_path:source ~mtime:0. ~chunk_size
         ~on_progress:(fun ~bytes:_ ~sent:_ ->
           incr landed;
           if !live_at_first_chunk = 0 then
             live_at_first_chunk :=
               (Stdlib.Gc.stat ()).Stdlib.Gc.live_words - baseline)
         ()
     in
     check "the fixture really is many chunks"
       ~why:(fun () -> Printf.sprintf "%d chunks landed" !landed)
       (!landed = chunks);
     check "and the manifest records every one of them"
       (Chunk_table.count manifest.Manifest.chunks = chunks);
     let per_chunk = !live_at_first_chunk / chunks in
     check "what is held does not grow with the length of the file"
       ~why:(fun () ->
         Printf.sprintf "%d words for %d chunks, %d each" !live_at_first_chunk
           chunks per_chunk)
       (per_chunk < 20);

     (* Held as a string the body would be a word per eight bytes, which for a
        terabyte's keys is four megabytes the collector scans and copies for
        nothing: what a manifest is never asked is what is inside it. *)
     case "a manifest body of many keys costs no OCaml heap";
     let keys = 50_000 in
     let digest i = Printf.sprintf "%016x" i in
     let before = (Stdlib.Gc.stat ()).Stdlib.Gc.live_words in
     let table =
       let b =
         Chunk_table.builder ~name:"big.bin" ~size:1_000_000L ~chunk_size
           ~mtime:0. ~symlink:None ~count:keys
       in
       for i = 0 to keys - 1 do
         Chunk_table.set b i (digest i ^ "-" ^ digest (i + 1))
       done;
       Chunk_table.of_chunk (Chunk_table.seal b ~h1:(digest 0) ~h2:(digest 1))
     in
     let held = (Stdlib.Gc.stat ()).Stdlib.Gc.live_words - before in
     check "the keys read back as they were written"
       (Chunk_table.key table 7 = digest 7 ^ "-" ^ digest 8);
     check "and the body they are in is not words the collector walks"
       ~why:(fun () ->
         Printf.sprintf "%d words held for %d keys, %d bytes of body" held keys
           (keys * 33))
       (held * 8 < keys * 33 / 4);

     (* A store is handed the body rather than an encoding of it, so what it
        takes and what a reader decodes have to be the same bytes. *)
     case "the body a store is handed is the one a reader decodes";
     let name = "big.bin" in
     check "under the name it records, byte for byte"
       (Chunk.to_string (Manifest.body ~name manifest)
       = Manifest.to_string ~name manifest);
     check "and under any other name, which is an encoding again"
       (Chunk.to_string (Manifest.body ~name:"filed-as.bin" manifest)
       = Manifest.to_string ~name:"filed-as.bin" manifest);

     (* A second upload of the same bytes takes the deduplicated path, which
        writes no chunk and so exercises the other branch of [put_chunk]. *)
     case "a deduplicated upload publishes the same body";
     let+ again =
       R.upload
         ~key:(C.domain_prefix ^ "copy.bin")
         ~src_path:source ~mtime:0. ~chunk_size ()
     in
     check "the two agree on the file's identity"
       (again.Manifest.h1 = manifest.Manifest.h1
       && again.Manifest.h2 = manifest.Manifest.h2);
     check "and on every chunk key"
       (List.init chunks (Chunk_table.key again.Manifest.chunks)
       = List.init chunks (Chunk_table.key manifest.Manifest.chunks));
     report ~expected:9 ())
