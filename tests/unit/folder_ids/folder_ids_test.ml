(* Reading a folder's path back out of its id.

   What an item identifier asks, and the answers that matter are the negative
   ones: a folder that is gone must resolve to nothing, or the caller goes on
   believing in a deleted directory. The index derives from the [.tsync-dir]
   markers, so it is also damaged deliberately here and checked to heal. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "folder-ids"
let cache_root = Filename.concat root "cache"
let domain_name = "testdom"

module Lk = Logical_key.Make (struct
  let domain_prefix = "tsync/testdom/manifests/"
end)

let ensure rel = Folder_ids_lwt.ensure_id ~cache_root ~domain_name (Lk.dir rel)
let lookup rel = Folder_ids_lwt.lookup_id ~cache_root ~domain_name (Lk.dir rel)

let rel_of id =
  let+ key =
    Folder_ids_lwt.key_of_id ~cache_root ~domain_name ~root:Lk.root id
  in
  Option.map Logical_key.path key

let reparent rel = Folder_ids_lwt.reparent ~cache_root ~domain_name (Lk.dir rel)

(* Named the way a caller holding a path does it, which is without knowing
   whether the path is a folder: the key is built as a file either way. *)
let item rel =
  let+ r = Folder_ids_lwt.ref_of_key ~cache_root ~domain_name (Lk.file rel) in
  Option.map Item_ref.to_string r

let rebuild () = Folder_ids_lwt.rebuild ~cache_root ~domain_name

let mirror rel =
  Filename.concat
    (Cache_layout.manifests_dir ~cache_root domain_name)
    (Stored_key.escape_path rel)

let index_file id =
  Filename.concat (Cache_layout.folders_dir ~cache_root domain_name) id

let main () =
  let* deep = ensure "a/b/c" in
  let* got = rel_of deep in
  check "a minted folder resolves back to its path" (got = Some "a/b/c");

  (* Intermediates are minted on the way: a folder with no id could not be named
     in a listing. *)
  let* a = lookup "a" in
  let* b = lookup "a/b" in
  check "ancestors are minted too" (a <> None && b <> None);
  let* got_a = rel_of (Option.get a) in
  check "an ancestor resolves too" (got_a = Some "a");

  (* The other direction, for a caller that has a path and needs the name the
     daemon knows: a folder answers to its own id, a file to its parent's and
     its leaf, and neither asks what kind it is first. *)
  let* dir_ref = item "a/b" in
  check "a folder is named by its own id" (dir_ref = Option.map (( ^ ) "d:") b);
  let* file_ref = item "a/b/note.txt" in
  check "a file is named by its folder and its leaf"
    (file_ref = Option.map (fun id -> "f:" ^ id ^ "/note.txt") b);
  let* root_ref = item "" in
  check "the domain root names itself" (root_ref = Some "root");
  let* stranded = item "nowhere/at/all" in
  check "a file under an unresolved folder has no name" (stranded = None);

  let* root_rel = rel_of Stored_key.root_id in
  check "the root resolves to the domain root" (root_rel = Some "");
  let* missing = rel_of "0000000000000000" in
  check "an unknown id resolves to nothing" (missing = None);

  let* () = Lwt_unix.rename (mirror "a/b") (mirror "a/moved") in
  let* () = reparent "a/moved" in
  let* got = rel_of deep in
  check "a renamed folder keeps its id" (got = Some "a/moved/c");
  let* still = lookup "a/moved" in
  check "the renamed folder is the same folder" (still = b);

  let* () = Io_lwt.Fs.rm_rf (mirror "a/moved") in
  let* gone = rel_of deep in
  check "a deleted folder resolves to nothing" (gone = None);
  let* gone_parent = rel_of (Option.get b) in
  check "its deleted parent does too" (gone_parent = None);

  let* other = ensure "elsewhere" in
  let* () =
    Io_lwt.Fs.atomic_write (index_file other)
      "{\"parent\":\".tsync-root\",\"name\":\"a\"}"
  in
  let* wrong = rel_of other in
  (* "a" exists but is a different folder, so the check against the markers
     rejects it. A lookup answers that and stops: repairing means walking the
     mirror, which is not a request's to pay. *)
  check "a corrupted entry does not resolve to another folder" (wrong = None);
  let* () = rebuild () in
  let* repaired = rel_of other in
  check "and a rebuild puts it right" (repaired = Some "elsewhere");

  let* () =
    Io_lwt.Fs.rm_rf (Cache_layout.folders_dir ~cache_root domain_name)
  in
  let* lost = rel_of other in
  check "a lost index answers nothing rather than rebuilding itself"
    (lost = None);
  let* () = rebuild () in
  let* healed = rel_of other in
  check "a lost index is restored by a rebuild" (healed = Some "elsewhere");

  let* stale = ensure "temporary" in
  let* () = Io_lwt.Fs.rm_rf (mirror "temporary") in
  let* () = rebuild () in
  let* exists = Io_lwt.Retry.file_exists (index_file stale) in
  check "rebuild prunes entries for departed folders" (not exists);

  (* Escaped names survive the round trip: the on-disk directory name is a hash
     when the real one is not portable, and nothing can decode it, so the real
     name has to come from the marker. *)
  let odd = "awkward:name" in
  let* odd_id = ensure odd in
  let* () =
    Io_lwt.Fs.rm_rf (Cache_layout.folders_dir ~cache_root domain_name)
  in
  let* () = rebuild () in
  let* got_odd = rel_of odd_id in
  check "a rebuilt index recovers an escaped name" (got_odd = Some odd);

  (* Depth is whatever the tree is. Single-character names because the ceiling
     that does exist is the filesystem's on the path, not this index's on the
     chain, and the point is to clear any fixed hop count comfortably. *)
  let deep_rel = String.concat "/" (List.init 300 (fun _ -> "a")) in
  let* deep_id = ensure deep_rel in
  let* deep_got = rel_of deep_id in
  check "a folder nested past any fixed cap resolves" (deep_got = Some deep_rel);

  (* Two entries naming each other: unreachable from the root, and the climb has
     to notice rather than follow it forever. *)
  let* () =
    Io_lwt.Fs.atomic_write
      (index_file "aaaaaaaaaaaaaaaa")
      "{\"parent\":\"bbbbbbbbbbbbbbbb\",\"name\":\"x\"}"
  in
  let* () =
    Io_lwt.Fs.atomic_write
      (index_file "bbbbbbbbbbbbbbbb")
      "{\"parent\":\"aaaaaaaaaaaaaaaa\",\"name\":\"y\"}"
  in
  let* looped = rel_of "aaaaaaaaaaaaaaaa" in
  check "a cycle in the index answers nothing rather than looping"
    (looped = None);

  Lwt.return_unit

let () =
  Lwt_main.run (main ());
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root)))
