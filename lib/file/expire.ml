open Lwt.Syntax

type stats = { versions_deleted : int; chunks_deleted : int; chunks_kept : int }

module Make (C : Conf.S) = struct
  let primary () =
    match C.backends with
      | b :: _ -> b
      | [] -> failwith "no backends configured"

  let delete_all keys =
    if keys = [] then Lwt.return_unit
    else
      Lwt_list.iter_s
        (fun (module B : Backend.S) -> B.delete_multi keys)
        C.backends

  let is_marker key = String.length key > 0 && key.[String.length key - 1] = '/'

  (* Chunk keys referenced by the manifest stored at [key]. Directory markers
     reference nothing; a dirty manifest is mid-write and has no committed
     chunks. An unexpected parse failure aborts (raises) rather than reporting
     "references nothing", which would let the sweep delete the file's chunks. *)
  let referenced_chunks (module B : Backend.S) key =
    if is_marker key then Lwt.return []
    else
      let+ data = B.get ~key () in
      match Folder.marker_of_string data with
        | Some _ -> [] (* folder / trash marker: references no chunks *)
        | None -> (
            match Manifest.of_string data with
              | `Clean m -> List.map Manifest.chunk_key m.Manifest.chunks
              | `Dirty -> []
              | exception e ->
                  failwith
                    (Printf.sprintf
                       "cannot read manifest %s (%s); aborting before chunk GC"
                       key (Printexc.to_string e)))

  let parse = Versioning.parse ~versions_prefix:C.versions_prefix

  (* All object keys under folder [folder_id] (recursively, following folder
     markers), including the markers themselves — the reclaim set for a trashed
     subtree. *)
  let rec collect_namespace (module B : Backend.S) folder_id acc =
    let* entries = B.list_all ~prefix:(C.domain_prefix ^ folder_id ^ "/") () in
    Lwt_list.fold_left_s
      (fun acc (e : Backend.file_entry) ->
        let* data = B.get ~key:e.key () in
        match Folder.marker_of_string data with
          | Some m -> collect_namespace (module B) m.Folder.id (e.key :: acc)
          | None -> Lwt.return (e.key :: acc))
      acc entries

  let expire ~cutoff () =
    let (module B : Backend.S) = primary () in
    let cutoff_ns = Int64.of_float (cutoff *. 1e9) in
    (* Phase 0: empty trashed folders past the cutoff. Delete the whole subtree
       under each expired trash marker (recursively by folder id) so its chunks
       drop out of the live set marked below. *)
    let* trash =
      B.list_all ~prefix:(C.domain_prefix ^ Folder.trash_id ^ "/") ()
    in
    let* trash_keys =
      Lwt_list.fold_left_s
        (fun acc (e : Backend.file_entry) ->
          if e.Backend.last_modified >= cutoff then Lwt.return acc
          else
            let* data = B.get ~key:e.key () in
            match Folder.marker_of_string data with
              | Some m ->
                  let+ subtree = collect_namespace (module B) m.Folder.id [] in
                  (e.key :: subtree) @ acc
              | None -> Lwt.return acc)
        [] trash
    in
    let* () = delete_all trash_keys in
    (* Phase 1: partition versions by the cutoff (no deletion yet). *)
    let* versions = B.list_all ~prefix:C.versions_prefix () in
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
    (* Phase 2: mark chunks referenced by live files and surviving versions.
       Done before any deletion so a bad manifest aborts with nothing removed.
       ponytail: GET per manifest — no chunk refcount index; add one only if a
       scan measurably hurts. *)
    let live = Hashtbl.create 4096 in
    let mark key =
      let+ cks = referenced_chunks (module B) key in
      List.iter (fun ck -> Hashtbl.replace live ck ()) cks
    in
    let* live_files = B.list_all ~prefix:C.domain_prefix () in
    let* () =
      Lwt_list.iter_s (fun (e : Backend.file_entry) -> mark e.key) live_files
    in
    let* () = Lwt_list.iter_s (fun (key, _rel) -> mark key) surviving in
    (* Phase 3: delete expired versions, then the version directories they
       emptied. On S3 no directory object exists, so those deletes are harmless
       no-ops; on a filesystem backend they prune the now-empty directory. *)
    let* () = delete_all (List.map fst expired) in
    let survivor_rels = List.map snd surviving in
    let* () =
      List.sort_uniq compare (List.map snd expired)
      |> List.filter (fun rel -> not (List.mem rel survivor_rels))
      |> List.map (fun rel -> C.versions_prefix ^ rel ^ "/")
      |> delete_all
    in
    (* Phase 4: sweep every chunk not referenced anywhere, regardless of age. *)
    let* chunks = B.list_all ~prefix:C.chunk_prefix () in
    let kept = ref 0 in
    let unreferenced =
      chunks
      |> List.filter_map (fun (e : Backend.file_entry) ->
          let ck =
            String.sub e.key
              (String.length C.chunk_prefix)
              (String.length e.key - String.length C.chunk_prefix)
          in
          if Hashtbl.mem live ck then (
            incr kept;
            None)
          else Some e.key)
    in
    let+ () = delete_all unreferenced in
    {
      versions_deleted = List.length expired;
      chunks_deleted = List.length unreferenced;
      chunks_kept = !kept;
    }
end
