(* Listing a directory after a rename.

   Two steps, and the failure needs both: a rename alone leaves a file that
   opens perfectly, and a listing alone is right until something has been
   renamed. Tests that renamed and then stat'd, or listed without renaming, all
   passed while a Syncthing folder on a mount re-downloaded the same gigabytes
   forever — every listing showed the name each file used to have, opening that
   name gave ENOENT, and the name that worked was in no listing at all.

   So what is printed here is the listing, before and after, for a published
   file and for a staged one. Both paths matter: a downloader renames its temp
   file the moment the bytes land, which is usually before the upload has. *)

open Lwt.Syntax
open Check

let root = "/tmp/tsync-rename-listing-test"
let store_dir = root ^ "/store"
let cache_dir = root ^ "/cache"
let data_dir = root ^ "/data"

(* 1980-01-01 UTC, so nothing drifts. Not [mtime]: the record literals below
   open Manifest, where that name is the accessor. *)
let fixed_mtime = 315532800.

module C =
  (val Fixture.conf ~max_uploads:2 ~max_downloads:2
         ~store:(Fixture.local_store store_dir)
         ~root ()
      : Conf.S)

module Lk = Logical_key.Make (C)
module Mf = Manifests_lwt.Make (C)
module Ck = Checkout_lwt.Make (C)
module Mfs = Staged_lwt.Manifest.Make (C)

let key rel = Lk.file @@ rel

let published ~name =
  Manifest_fixture.make ~name ~h1:"1111111111111111" ~h2:"2222222222222222"
    ~size:4L ~chunk_size:8
    ~chunks:
      [
        Manifest.
          {
            index = 0;
            h1 = "3333333333333333";
            h2 = "4444444444444444";
            size = 4;
          };
      ]
    ~mtime:fixed_mtime

let staged ~name =
  Staged_manifest.
    {
      s_name = name;
      s_size = 4L;
      s_mtime = fixed_mtime;
      s_chunk_size = 8;
      s_slots = [||];
      s_whole = None;
    }

(* What the directory shows, which is the thing that was wrong. *)
let listing () =
  let+ files, dirs = Ck.list_children ~prefix:Lk.root () in
  let names =
    List.map (fun (e : Checkout.listed) -> Logical_key.leaf e.key) files
  in
  List.iter (Printf.printf "  dir  %s\n") (List.sort compare dirs);
  List.iter (Printf.printf "  file %s\n") (List.sort compare names)

(* Whether the listed name can actually be opened. A name in a listing that
   resolves to nothing is the shape of the failure: `ls` shows it, opening it
   does not. *)
let resolves rel =
  let+ m = Mf.published (key rel) in
  Printf.printf "  %s resolves: %b\n" rel (m <> None)

let () =
  Lwt_main.run
    (let* () = Io_lwt.Fs.rm_rf root in
     case "a published file, renamed";
     let* () = Mf.write (key "a.tmp") (published ~name:"a.tmp") in
     let* () = listing () in
     let* () = Ck.rename ~src_key:(key "a.tmp") ~dst_key:(key "a.final") in
     Printf.printf "  -- renamed a.tmp -> a.final\n";
     let* () = listing () in
     let* () = resolves "a.final" in
     let* () = resolves "a.tmp" in

     case "a staged file, renamed before its upload lands";
     let* () = Mfs.write (key "b.tmp") (staged ~name:"b.tmp") in
     let* () = listing () in
     let* () = Mfs.rename ~src_key:(key "b.tmp") ~dst_key:(key "b.final") in
     Printf.printf "  -- renamed b.tmp -> b.final\n";
     let+ () = listing () in
     ());
  Lwt_main.run (Io_lwt.Fs.rm_rf root)
