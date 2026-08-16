(* What the sidecar cache is allowed to hold on to.

   A cached manifest keeps the mapping it was read through, so the table bounds
   live mappings and not merely bytes. Unbounded, an import that reads one
   sidecar per file ends up holding one mapping per file: the run that found
   this had 19,261 of them, against 75 MB of pinned page cache.

   The count is asserted in both directions, because a cache that stored
   nothing would satisfy a bound just as well as one that works. *)

open Lwt.Syntax

let root = Filename.temp_dir "tsync-manifest-memo" ""
let domain = "testdom"
let failures = ref 0

let check name ok =
  if ok then Printf.printf "%s: ok\n%!" name
  else begin
    incr failures;
    Printf.printf "%s: FAILED\n%!" name
  end

module Store =
  (val Backend.make ~backend_type:"local" ~get_field:(fun _ ->
           Some (Filename.concat root "store")))

module C : Conf.S = struct
  let versioning = false
  let client_name = "test"
  let domain_name = domain
  let domain_prefix = "tsync/" ^ domain ^ "/manifests/"
  let chunk_prefix = "tsync/" ^ domain ^ "/chunks/"
  let versions_prefix = "tsync/" ^ domain ^ "/versions/"
  let journal_prefix = "tsync/" ^ domain ^ "/journal/"
  let cursor_key = "tsync/" ^ domain ^ "/cursor"
  let shares_prefix = "tsync/shares/"
  let store = (module Store : Backend.S)
  let members = [Backend.member ~name:"local" store]
  let cache_root = root
  let data_dir = root
  let socket_path = ""
  let max_uploads = 1
  let max_chunk_buffers = 1
  let max_downloads = 1
  let chunk_size = Some (8 * 1024 * 1024)
  let cache_chunk_size = Some (8 * 1024 * 1024)
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module Mf = Manifest.Make (C)

let key i = C.domain_prefix ^ Printf.sprintf "f%05d.txt" i

let write_sidecar i =
  let name = Printf.sprintf "f%05d.txt" i in
  let m =
    Manifest.of_string
      (Chunk_table.encode ~name ~size:5L ~chunk_size:4 ~mtime:0.
         ~h1:(String.make 16 'a') ~h2:(String.make 16 'b') ~symlink:None
         ~keys:[])
  in
  Mf.write (key i) m

(* Written and then read, as an import does: [write] drops the key from the
   cache, so only the read puts it back. *)
let touch i =
  let* () = write_sidecar i in
  let+ (_ : Manifest.t option) = Mf.read (key i) in
  ()

let () =
  Lwt_main.run
    (let* () = touch 0 in
     check "a read caches the manifest" (Mf.memo_size () = 1);
     let* m = Mf.read (key 0) in
     check "and answers with it"
       (match m with Some m -> m.Manifest.size = 5L | None -> false);

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
     let* m = Mf.read (key 0) in
     check "an evicted key still reads"
       (match m with Some m -> m.Manifest.size = 5L | None -> false);

     if !failures > 0 then exit 1;
     Lwt.return_unit)
