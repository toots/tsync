(* A domain's manifests are remembered once however many places name them.

   [Manifests_lwt.Make] is applied wherever a manifest is read or written -- the
   tree, the content layer, the file operations -- and each application used to
   carry a table of its own. Nothing was served stale by that: an entry records
   the inode, size and mtime it was read through, so a manifest replaced by any
   writer, in this process or another, is re-read. What it cost was the reading:
   one table per application, each missing on what the others had.

   So what is pinned here is the sharing itself, and that it is per domain. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "manifests-memo"
let domain = "testdom"

module Store =
  (val Backend_lwt.make ~backend_type:"local"
         ~get_field:(fun _ -> Some (Filename.concat root "store"))
         ())

let conf ~domain =
  Fixture.conf ~domain
    ~chunk_size:(8 * 1024 * 1024)
    ~cache_chunk_size:(8 * 1024 * 1024)
    ~store:(module Store : Backend_lwt.Store)
    ~cache_root:root ~data_dir:root ~root ()

module C = (val conf ~domain : Conf.S)
module Lk = Logical_key.Make (C)
module A = Manifests_lwt.Make (C)
module B = Manifests_lwt.Make (C)
module D = (val conf ~domain:"otherdom" : Conf.S)
module E = Manifests_lwt.Make (D)

let key = Lk.file "a.txt"

let manifest ~size =
  Manifest.of_string
    (Manifest.encode ~name:"a.txt" ~size:(Int64.of_int size) ~chunk_size:4
       ~mtime:0. ~h1:(String.make 16 'a') ~h2:(String.make 16 'b') ~symlink:None
       ~keys:[])

let () =
  Lwt_main.run
    (let* () = A.ensure_parent key in

     case "written through one application";
     let* () = A.write key (manifest ~size:11) in
     let* m = B.published key in
     check "is read through another"
       (match m with Some m -> Manifest.size m = 11L | None -> false);

     case "written again";
     let* () = A.write key (manifest ~size:22) in
     let* m = B.published key in
     check "the other does not serve what it read before"
       (match m with Some m -> Manifest.size m = 22L | None -> false);

     case "the memo";
     check "is one table, not two" (A.memo_size () = B.memo_size ());
     check "and a second domain keeps its own" (E.memo_size () = 0);
     report ~expected:4 ();
     Lwt.return_unit)
