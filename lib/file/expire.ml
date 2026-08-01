open Lwt.Syntax

type stats = {
  versions_deleted : int;
  chunks_deleted : int;
  chunks_kept : int;
  journal_deleted : int;
}

module Make (C : Conf.S) = struct
  module Bk = Backends.Make (C)
  module Fs = File_store.Make (C)
  module Tree = Inode_tree.Make (C)

  let primary = Bk.primary
  let delete_all = Bk.delete_many

  (* Directory markers reference nothing; a dirty manifest is mid-write and has
     no committed chunks. An unexpected parse failure raises rather than
     reporting "references nothing", which would let the sweep delete the file's
     chunks. *)
  let referenced_chunks (module B : Backend.S) key =
    if Key.is_dir key then Lwt.return []
    else
      let+ data = B.get ~key () in
      match Folder.marker_of_string data with
        | Some _ -> [] (* folder / trash marker: references no chunks *)
        | None -> (
            match Manifest.of_string data with
              | m ->
                  let t = m.Manifest.chunks in
                  List.init (Chunk_table.count t) (Chunk_table.key t)
              | exception e ->
                  failwith
                    (Printf.sprintf
                       "cannot read manifest %s (%s); aborting before chunk GC"
                       key (Printexc.to_string e)))

  let parse = Versioning.parse ~versions_prefix:C.versions_prefix

  (* The reclaim set for a trashed subtree, markers included. Errors propagate: a
     short list would leave part of the subtree undeleted while its parent marker
     goes. *)
  let collect_namespace folder_id acc =
    Tree.fold_tree ~folder_id ~rel:""
      (fun acc _rel entry -> Lwt.return (entry.Inode_tree.bkey :: acc))
      acc

  let expire ~cutoff () =
    let (module B : Backend.S) = primary () in
    let cutoff_ns = Int64.of_float (cutoff *. 1e9) in
    (* Phase 0: empty trashed folders past the cutoff, whole subtree at a time,
       so their chunks drop out of the live set marked below. *)
    let* trash =
      B.list_prefix ~prefix:(C.domain_prefix ^ Folder.trash_id ^ "/") ()
    in
    let* trash_keys =
      Lwt_list.fold_left_s
        (fun acc (e : Backend.file_entry) ->
          if e.Backend.last_modified >= cutoff then Lwt.return acc
          else
            let* data = B.get ~key:e.key () in
            match Folder.marker_of_string data with
              | Some m ->
                  let+ subtree = collect_namespace m.Folder.id [] in
                  (e.key :: subtree) @ acc
              | None -> Lwt.return acc)
        [] trash
    in
    let* () = delete_all trash_keys in
    (* Phase 1: partition versions by the cutoff (no deletion yet). *)
    let* versions = B.list_prefix ~prefix:C.versions_prefix () in
    let expired, surviving =
      versions
      |> List.fold_left
           (fun (expired, surviving) (e : Backend.file_entry) ->
             match parse e.key with
               | Some (rel, ts)
                 when Int64.compare (Int64.of_string ts) cutoff_ns < 0 ->
                   ((e.key, rel) :: expired, surviving)
               | Some (rel, _) -> (expired, (e.key, rel) :: surviving)
               | None -> (expired, surviving))
           ([], [])
    in
    (* Phase 2: mark chunks referenced by live files and surviving versions,
       before any deletion, so a bad manifest aborts with nothing removed.
       ponytail: GET per manifest — no chunk refcount index; add one only if a
       scan measurably hurts. *)
    let live = Hashtbl.create 4096 in
    let mark key =
      let+ cks = referenced_chunks (module B) key in
      List.iter (fun ck -> Hashtbl.replace live ck ()) cks
    in
    let* live_files = B.list_prefix ~prefix:C.domain_prefix () in
    let* () =
      Lwt_list.iter_s (fun (e : Backend.file_entry) -> mark e.key) live_files
    in
    let* () = Lwt_list.iter_s (fun (key, _rel) -> mark key) surviving in
    (* Phase 3: delete expired versions, then the version directories they
       emptied. No-ops on S3, where no directory object exists. *)
    let* () = delete_all (List.map fst expired) in
    let survivor_rels = List.map snd surviving in
    let* () =
      List.sort_uniq compare (List.map snd expired)
      |> List.filter (fun rel -> not (List.mem rel survivor_rels))
      |> List.map (fun rel -> C.versions_prefix ^ rel ^ "/")
      |> delete_all
    in
    (* Phase 4: sweep every chunk not referenced anywhere, regardless of age. *)
    let* chunks = B.list_prefix ~prefix:C.chunk_prefix () in
    let kept = ref 0 in
    let unreferenced =
      chunks
      |> List.filter_map (fun (e : Backend.file_entry) ->
          (* Sharded ({!Chunk_layout}), so the key is the entry's last path
             segment, not everything past the prefix. *)
          let ck = Filename.basename e.key in
          if Hashtbl.mem live ck then (
            incr kept;
            None)
          else Some e.key)
    in
    let* () = delete_all unreferenced in
    (* Phase 5: drop journal entries older than the cutoff. The journal only
       grows — one object per write — and nothing else prunes it. Age is the only
       safe criterion: the cursor says what was published, not what every client
       has applied, so entries above it are still owed to clients that are behind.
       A client offline longer than the retention window must resync anyway, the
       versions and trashed files it missed being gone too.

       The entry the cursor names is kept whatever its age, or a quiet domain
       whose last write predates the cutoff is left with a cursor pointing at
       nothing. *)
    let* cursor = Fs.fetch_cursor () in
    let cutoff_ms = Int64.of_float (cutoff *. 1000.) in
    let* journal = B.list_prefix ~prefix:C.journal_prefix () in
    let stale =
      journal
      |> List.filter (fun (e : Backend.file_entry) ->
          let ek = Filename.basename e.key in
          match Journal.timestamp_ms_of_filename ek with
            | ms -> ms < cutoff_ms && Some ek <> cursor
            | exception _ -> false)
      |> List.map (fun (e : Backend.file_entry) -> e.key)
    in
    let+ () = delete_all stale in
    {
      versions_deleted = List.length expired;
      chunks_deleted = List.length unreferenced;
      chunks_kept = !kept;
      journal_deleted = List.length stale;
    }
end
