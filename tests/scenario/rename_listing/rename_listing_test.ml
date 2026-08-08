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

let root = "/tmp/tsync-rename-listing-test"
let store_dir = root ^ "/store"
let cache_dir = root ^ "/cache"
let data_dir = root ^ "/data"
let mtime = 315532800. (* 1980-01-01 UTC, so nothing drifts *)

module C : Conf.S = struct
  let versioning = false
  let client_name = "test"
  let domain_name = "testdom"
  let domain_prefix = "tsync/testdom/manifests/"
  let chunk_prefix = "tsync/testdom/chunks/"
  let versions_prefix = "tsync/testdom/versions/"
  let journal_prefix = "tsync/testdom/journal/"
  let cursor_key = "tsync/testdom/cursor"
  let shares_prefix = "tsync/shares/"
  let store = Local_backend.make ~root:store_dir
  let members = [Backend.member ~name:"local" store]
  let cache_root = cache_dir
  let data_dir = data_dir
  let socket_path = ""
  let max_uploads = 1
  let max_chunk_buffers = 1
  let max_downloads = 2
  let chunk_size = Some 8
  let cache_chunk_size = Some 8
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module Mf = Manifest.Make (C)

let key rel = C.domain_prefix ^ rel
let case name = Printf.printf "\n=== %s\n" name

let published ~name =
  Manifest.make ~name ~h1:"1111111111111111" ~h2:"2222222222222222" ~size:4L
    ~chunk_size:8
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
    ~mtime

let staged ~name =
  Manifest.
    {
      s_name = name;
      s_size = 4L;
      s_mtime = mtime;
      s_chunk_size = 8;
      s_slots = [||];
      s_whole = None;
      s_published = None;
    }

(* What the directory shows, which is the thing that was wrong. *)
let listing () =
  let+ files, dirs = Mf.list_children ~prefix:C.domain_prefix () in
  let names =
    List.map
      (fun (e : Backend.file_entry) ->
        Key.leaf ~domain_prefix:C.domain_prefix e.Backend.key)
      files
  in
  List.iter (Printf.printf "  dir  %s\n") (List.sort compare dirs);
  List.iter (Printf.printf "  file %s\n") (List.sort compare names)

(* Whether the listed name can actually be opened. A name in a listing that
   resolves to nothing is the shape of the failure: `ls` shows it, opening it
   does not. *)
let resolves rel =
  let+ m = Mf.read (key rel) in
  Printf.printf "  %s resolves: %b\n" rel (m <> None)

let () =
  Lwt_main.run
    (let* () = Fs_util.rm_rf root in
     case "a published file, renamed";
     let* () = Mf.write (key "a.tmp") (published ~name:"a.tmp") in
     let* () = listing () in
     let* () = Mf.rename ~src_key:(key "a.tmp") ~dst_key:(key "a.final") in
     Printf.printf "  -- renamed a.tmp -> a.final\n";
     let* () = listing () in
     let* () = resolves "a.final" in
     let* () = resolves "a.tmp" in

     case "a staged file, renamed before its upload lands";
     let* () = Mf.write_staged (key "b.tmp") (staged ~name:"b.tmp") in
     let* () = listing () in
     let* () =
       Mf.rename_staged ~src_key:(key "b.tmp") ~dst_key:(key "b.final")
     in
     Printf.printf "  -- renamed b.tmp -> b.final\n";
     let+ () = listing () in
     ());
  Lwt_main.run (Fs_util.rm_rf root)
