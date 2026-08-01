(* The staged write path: what a local edit does to a published file.

   Chunk size is 8, so the 24-byte fixture is three chunks and a write can be
   made to cover one chunk wholly, partly, or to run off the end. Each step
   prints the file's size, its per-chunk slots and the chunk-cache count —
   which together say exactly which bytes came from where:
     S = a staged body (locally written), I = still inherited from the published
     manifest, Z = a hole from a grow (zeros, no disk).
   The chunk count is what proves a read-modify-write fetched one chunk and a
   grow fetched none. *)

open Lwt.Syntax

let root = "/tmp/tsync-staged-test"
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
  let backends = [Local_backend.make ~root:store_dir]
  let share_backends = backends
  let cache_root = cache_dir
  let data_dir = data_dir
  let socket_path = ""
  let max_uploads = 1
  let max_downloads = 2
  let chunk_size = Some 8
  let cache_chunk_size = Some 8
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module R = Remote.Make (C)
module Mf = Manifest.Make (C)
module D = Data.Make (C) (R)

let key = C.domain_prefix ^ "file.txt"
let body = "abcdefghijklmnopqrstuvwx" (* 24 bytes = 3 chunks *)

let chunk_count () =
  let rec count dir =
    if not (Sys.file_exists dir) then 0
    else
      Array.fold_left
        (fun n name ->
          let p = Filename.concat dir name in
          if Sys.is_directory p then n + count p else n + 1)
        0 (Sys.readdir dir)
  in
  count (Cache_layout.chunks_dir ~cache_root:C.cache_root C.domain_name)

let read_all () =
  let* resolved = Mf.resolve key in
  let size =
    match resolved with
      | Some (`Staged (st, _)) -> Int64.to_int st.Manifest.s_size
      | Some (`Published m) -> Int64.to_int m.Manifest.size
      | None -> 0
  in
  if size = 0 then Lwt.return ""
  else (
    let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout size in
    let+ n = D.pread_key key buf ~offset:0L in
    String.init n (Bigarray.Array1.get buf))

let show label =
  let* resolved = Mf.resolve key in
  let state =
    match resolved with
      | Some (`Staged (({ Manifest.s_whole = Some _; _ } as st), _)) ->
          Printf.sprintf "staged size=%2Ld whole" st.Manifest.s_size
      | Some (`Staged (st, _)) ->
          Printf.sprintf "staged size=%2Ld slots=[%s]" st.Manifest.s_size
            (String.concat ""
               (Array.to_list
                  (Array.map
                     (function
                       | Manifest.Staged _ -> "S"
                       | Manifest.Inherit -> "I"
                       | Manifest.Zero -> "Z")
                     st.Manifest.s_slots)))
      | Some (`Published m) ->
          Printf.sprintf "published size=%2Ld chunks=%d" m.Manifest.size
            (Chunk_table.count m.Manifest.chunks)
      | None -> "absent"
  in
  let+ content = read_all () in
  Printf.printf "%-26s %-34s cached=%d %S\n" label state (chunk_count ())
    content

let publish () =
  let src = Filename.concat data_dir "file.txt" in
  let oc = open_out_bin src in
  output_string oc body;
  close_out oc;
  let* chunk_size = R.chunk_size () in
  let* state = R.upload ~key ~src_path:src ~mtime ~chunk_size () in
  Mf.write key state

let write_at offset s =
  let n = String.length s in
  let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout n in
  String.iteri (fun i c -> Bigarray.Array1.set buf i c) s;
  let+ (_ : int) = D.write key buf ~offset:(Int64.of_int offset) in
  ()

(* Three stored chunks of 8 to one cache chunk of 24. Its own domain, so its
   cache subtree can be counted separately. *)
module CG : Conf.S = struct
  include C

  let domain_name = "groupdom"
  let domain_prefix = "tsync/groupdom/manifests/"
  let chunk_prefix = "tsync/groupdom/chunks/"
  let cache_chunk_size = Some 24
end

module GR = Remote.Make (CG)
module Gm = Manifest.Make (CG)
module GD = Data.Make (CG) (GR)

let gkey = CG.domain_prefix ^ "file.txt"

let gchunk_count () =
  let rec count dir =
    if not (Sys.file_exists dir) then 0
    else
      Array.fold_left
        (fun n name ->
          let p = Filename.concat dir name in
          if Sys.is_directory p then n + count p else n + 1)
        0 (Sys.readdir dir)
  in
  count (Cache_layout.chunks_dir ~cache_root:CG.cache_root CG.domain_name)

let gpublish () =
  let src = Filename.concat data_dir "grouped.txt" in
  let oc = open_out_bin src in
  output_string oc body;
  close_out oc;
  let* chunk_size = GR.chunk_size () in
  let* state = GR.upload ~key:gkey ~src_path:src ~mtime ~chunk_size () in
  Gm.write gkey state

let gwrite_at offset s =
  let n = String.length s in
  let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout n in
  String.iteri (fun i c -> Bigarray.Array1.set buf i c) s;
  let+ (_ : int) = GD.write gkey buf ~offset:(Int64.of_int offset) in
  ()

let gshow label =
  let* resolved = Gm.resolve gkey in
  let state =
    match resolved with
      | Some (`Staged (st, _)) ->
          Printf.sprintf "staged size=%2Ld slots=[%s]" st.Manifest.s_size
            (String.concat ""
               (Array.to_list
                  (Array.map
                     (function
                       | Manifest.Staged _ -> "S"
                       | Manifest.Inherit -> "I"
                       | Manifest.Zero -> "Z")
                     st.Manifest.s_slots)))
      | Some (`Published m) ->
          Printf.sprintf "published size=%2Ld chunks=%d" m.Manifest.size
            (Chunk_table.count m.Manifest.chunks)
      | None -> "absent"
  in
  let size =
    match resolved with
      | Some (`Staged (st, _)) -> Int64.to_int st.Manifest.s_size
      | Some (`Published m) -> Int64.to_int m.Manifest.size
      | None -> 0
  in
  let+ content =
    if size = 0 then Lwt.return ""
    else (
      let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout size in
      let+ n = GD.pread_key gkey buf ~offset:0L in
      String.init n (Bigarray.Array1.get buf))
  in
  Printf.printf "%-26s %-34s cached=%d %S\n" label state (gchunk_count ())
    content

let () =
  ignore
    (Sys.command
       (Printf.sprintf "rm -rf %s && mkdir -p %s %s %s" root store_dir cache_dir
          data_dir));
  Lwt_main.run
    (let* () = Mf.init () in
     let* () = publish () in
     let* () = show "published" in

     (* A partial write of one chunk must copy that chunk in (read-modify-write)
        and touch no other. *)
     let* () = write_at 9 "ZZ" in
     let* () = show "write 2B into chunk 1" in

     (* A write covering a whole chunk needs none of its old bytes. *)
     let* () = write_at 16 "QRSTUVWX" in
     let* () = show "overwrite chunk 2 whole" in

     (* Past the end: the file grows and the new chunk is staged. *)
     let* () = write_at 24 "!!" in
     let* () = show "append past EOF" in

     (* An append straddling a chunk boundary stages both chunks it lands in. *)
     let* () = write_at 24 "!!!!!!!!!!" in
     let* () = show "append across a chunk boundary" in

     (* Shrink into the middle of a chunk: the tail body goes, the boundary
        chunk is resized. *)
     let* () = D.truncate key 10L in
     let* () = show "truncate to 10" in

     (* Grow: pure metadata, zeros on read, not one chunk fetched. *)
     let* () = D.truncate key 20L in
     let* () = show "grow to 20" in

     (* Back to a normal edited file, then sync it. *)
     let* () = D.truncate key 24L in
     let* () = write_at 0 "ABCDEFGH" in
     let* () = show "edit chunk 0" in
     let* () = D.sync key () in
     let* () = show "after sync" in

     (* A published file edited in one chunk must re-upload that chunk and no
        other: the untouched ones stay [Inherit] and keep their entries. *)
     let backend_chunks () =
       let (module B : Backend.S) = List.hd C.backends in
       let+ entries = B.list_prefix ~prefix:C.chunk_prefix () in
       List.length entries
     in
     let* before = backend_chunks () in
     let* () = write_at 0 "XY" in
     let* () = show "edit 2B of chunk 0" in
     let* () = D.sync key () in
     let* after = backend_chunks () in
     Printf.printf "chunk objects added by a 1-chunk edit: %d\n" (after - before);

     (* A crash between the commit record and the local moves must replay
        without re-uploading: stage an edit, sync it, then put the staged
        manifest back with its published record and sync again. *)
     let* () = write_at 8 "01234567" in
     let* staged_before = Mf.read_staged key in
     let* () = D.sync key () in
     let* published = Mf.read key in
     let* () =
       match (staged_before, published) with
         | Some st, Some m ->
             Mf.write_staged key { st with Manifest.s_published = Some m }
         | _ -> Lwt.return_unit
     in
     let uploaded_before = Metrics.uploaded () in
     let* () = D.sync key () in
     let uploaded_after = Metrics.uploaded () in
     let* () = show "replayed promotion" in
     Printf.printf "bytes uploaded by replay: %d\n"
       (uploaded_after - uploaded_before);

     (* The other crash window: chunks were PUT but the commit record never
        landed, so the upload runs again. Every chunk hashes as before, so the
        HEADs skip and no bytes go out twice. *)
     let* () = write_at 16 "89ABCDEF" in
     let* staged_before = Mf.read_staged key in
     let* () = D.sync key () in
     let* () =
       match staged_before with
         | Some st -> Mf.write_staged key st
         | None -> Lwt.return_unit
     in
     let uploaded_before = Metrics.uploaded () in
     let* () = D.sync key () in
     let uploaded_after = Metrics.uploaded () in
     let* () = show "re-uploaded without the commit record" in
     Printf.printf "bytes uploaded by re-upload: %d\n"
       (uploaded_after - uploaded_before);

     (* A frontend giving back a complete file (as the FileProvider extension
        always does) has it adopted where it is: one rename, no copy, no chunking
        pass. Reads come straight out of that file. *)
     let handed = Filename.concat data_dir "handed.bin" in
     let oc = open_out_bin handed in
     output_string oc "WHOLE FILE FROM A FRONTEND";
     close_out oc;
     let* () = D.stage_whole key ~src_path:handed in
     Printf.printf "handed-over file still at its old path: %b\n"
       (Sys.file_exists handed);
     let* () = show "adopted whole file" in

     (* A byte write into a whole-staged file splits it into chunks first: the
        only path needing it, a whole-file frontend never writing ranges. *)
     let* () = write_at 6 "-" in
     let* () = show "byte write splits it" in
     let* () = D.sync key () in
     let* () = show "after sync" in

     (* And the whole file straight to the backend, no split. *)
     let oc = open_out_bin handed in
     output_string oc "SECOND HANDOFF";
     close_out oc;
     let* () = D.stage_whole key ~src_path:handed in
     let* () = D.sync key () in
     let* () = show "whole file uploaded as-is" in

     (* And back to nothing. *)
     let* () = D.create key in
     let* () = show "create (O_TRUNC)" in

     (* Same file and stored chunks, but a cache chunk size of 24 puts all three
        in one cache file. Two things change: a write stages the whole group
        rather than the chunk it touches, and promotion writes that group out of
        the staged bodies instead of leaving it to be fetched. *)
     let* () = Gm.init () in
     let* () = gpublish () in
     let* () = gshow "grouped: published" in

     (* One 2-byte write, and every slot of the group is staged: the group's key
        changed, so its other members cannot be left pointing at the old one. *)
     let* () = gwrite_at 9 "ZZ" in
     let* () = gshow "grouped: write 2B" in

     (* The file is wholly cached afterwards without a fetch: three stored chunks
        in one cache file. The second file is the pre-edit group — its members
        changed, so its key did — and is garbage for the cap to reclaim. *)
     let* () = GD.sync gkey () in
     let* () = gshow "grouped: after sync" in
     let* present, total = GD.chunk_residency gkey in
     Printf.printf
       "grouped: cached %d/%d chunks, %d cache file(s) incl. stale\n" present
       total (gchunk_count ());
     Lwt.return_unit)
