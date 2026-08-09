(* Reading a folder's path back out of its id.

   What an item identifier asks, and the answers that matter are the negative
   ones: a folder that is gone must resolve to nothing, or the caller goes on
   believing in a deleted directory. The index derives from the [.tsync-dir]
   markers, so it is also damaged deliberately here and checked to heal. *)

open Lwt.Syntax

let root = Filename.temp_dir "tsync-folder-ids" ""
let cache_root = Filename.concat root "cache"
let domain_name = "testdom"
let failures = ref 0

let check name ok =
  if ok then Printf.printf "%s: ok\n%!" name
  else begin
    incr failures;
    Printf.printf "%s: FAILED\n%!" name
  end

let ensure rel = Folder_ids.ensure_id ~cache_root ~domain_name rel
let lookup rel = Folder_ids.lookup_id ~cache_root ~domain_name rel
let rel_of id = Folder_ids.rel_of_id ~cache_root ~domain_name id
let reparent rel = Folder_ids.reparent ~cache_root ~domain_name rel
let rebuild () = Folder_ids.rebuild ~cache_root ~domain_name

let mirror rel =
  Filename.concat
    (Cache_layout.manifests_dir ~cache_root domain_name)
    (Name_escape.encode_key rel)

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

  let* root_rel = rel_of Folder.root_id in
  check "the root resolves to the domain root" (root_rel = Some "");
  let* missing = rel_of "0000000000000000" in
  check "an unknown id resolves to nothing" (missing = None);

  let* () = Lwt_unix.rename (mirror "a/b") (mirror "a/moved") in
  let* () = reparent "a/moved" in
  let* got = rel_of deep in
  check "a renamed folder keeps its id" (got = Some "a/moved/c");
  let* still = lookup "a/moved" in
  check "the renamed folder is the same folder" (still = b);

  let* () = Fs_util.rm_rf (mirror "a/moved") in
  let* gone = rel_of deep in
  check "a deleted folder resolves to nothing" (gone = None);
  let* gone_parent = rel_of (Option.get b) in
  check "its deleted parent does too" (gone_parent = None);

  let* other = ensure "elsewhere" in
  let* () =
    Fs_util.atomic_write (index_file other)
      "{\"parent\":\".tsync-root\",\"name\":\"a\"}"
  in
  let* wrong = rel_of other in
  (* "a" exists but is a different folder, so the check against the markers
     rejects it; the rebuild that follows restores the truth. *)
  check "a corrupted entry does not resolve to another folder"
    (wrong = Some "elsewhere");

  let* () = Fs_util.rm_rf (Cache_layout.folders_dir ~cache_root domain_name) in
  let* healed = rel_of other in
  check "a lost index is rebuilt on demand" (healed = Some "elsewhere");

  let* stale = ensure "temporary" in
  let* () = Fs_util.rm_rf (mirror "temporary") in
  let* () = rebuild () in
  let* exists = Lwt_unix_retry.file_exists (index_file stale) in
  check "rebuild prunes entries for departed folders" (not exists);

  (* Escaped names survive the round trip: the on-disk directory name is a hash
     when the real one is not portable, and nothing can decode it, so the real
     name has to come from the marker. *)
  let odd = "awkward:name" in
  let* odd_id = ensure odd in
  let* () = Fs_util.rm_rf (Cache_layout.folders_dir ~cache_root domain_name) in
  let* got_odd = rel_of odd_id in
  check "a rebuilt index recovers an escaped name" (got_odd = Some odd);

  Lwt.return_unit

let () =
  Lwt_main.run (main ());
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root)))
