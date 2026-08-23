(* What the sidecar cache is allowed to hold on to.

   A cached manifest keeps the mapping it was read through, so the table bounds
   live mappings and not merely bytes. Unbounded, an import that reads one
   sidecar per file ends up holding one mapping per file: the run that found
   this had 19,261 of them, against 75 MB of pinned page cache.

   The count is asserted in both directions, because a cache that stored
   nothing would satisfy a bound just as well as one that works. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "manifest-memo"
let domain = "testdom"

module Store =
  (val Backend.make ~backend_type:"local"
         ~get_field:(fun _ -> Some (Filename.concat root "store"))
         ())

module C =
  (val Fixture.conf ~domain
         ~chunk_size:(8 * 1024 * 1024)
         ~cache_chunk_size:(8 * 1024 * 1024)
         ~store:(module Store : Backend.S)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf.S)

module Lk = Logical_key.Make (C)
module Mf = Checkout.Make (C)
module Mfs = Staged_manifest.Make (C)

let key i = Lk.file @@ Printf.sprintf "f%05d.txt" i

let write_sidecar i =
  let name = Printf.sprintf "f%05d.txt" i in
  let m =
    Manifest.of_string
      (Manifest.encode ~name ~size:5L ~chunk_size:4 ~mtime:0.
         ~h1:(String.make 16 'a') ~h2:(String.make 16 'b') ~symlink:None
         ~keys:[])
  in
  Mf.write (key i) m

(* Written and then read, as an import does: [write] drops the key from the
   cache, so only the read puts it back. *)
let touch i =
  let* () = write_sidecar i in
  let+ (_ : Manifest.t option) = Mf.published (key i) in
  ()

let () =
  Lwt_main.run
    (let* () = touch 0 in
     check "a read caches the manifest" (Mf.memo_size () = 1);
     let* m = Mf.published (key 0) in
     check "and answers with it"
       (match m with Some m -> Manifest.size m = 5L | None -> false);

     let rec go i =
       if i > 1200 then Lwt.return_unit
       else
         let* () = touch i in
         go (i + 1)
     in
     let* () = go 1 in

     (* 1201 sidecars read, so an unbounded cache would hold all of them. *)
     let n = Mf.memo_size () in
     check (Printf.sprintf "1201 reads leave %d cached, bounded" n) (n < 1201);
     check "the cache is full rather than empty" (n > 0);

     (* Evicted, so served from the file again -- the manifest is the same
        either way, which is why the count is what gets asserted. *)
     let* m = Mf.published (key 0) in
     check "an evicted key still reads"
       (match m with Some m -> Manifest.size m = 5L | None -> false);

     report ();
     Lwt.return_unit)
