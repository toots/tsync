open Lwt.Syntax

type stats = { versions_deleted : int; journal_deleted : int }

module Make (C : Conf_lwt.S) = struct
  module Lk = Logical_key.Make (C)
  module Fs = File_store_lwt.Make (C)
  module Tree = Inode_tree_lwt.Make (C)
  module B = (val C.store : C.Store)

  (* Deleted in batches rather than one call with everything, so a long delete
     reports progress from inside it. 1000 matches what the object stores accept
     per request, so batching here costs a driver nothing. *)
  let delete_batch = 1000

  let delete_all ~name ~on_delete keys =
    let rec go done_ = function
      | [] -> Lwt.return_unit
      | keys ->
          let batch = List.filteri (fun i _ -> i < delete_batch) keys in
          let rest = List.filteri (fun i _ -> i >= delete_batch) keys in
          let* () = B.delete_multi batch in
          let done_ = done_ + List.length batch in
          Log.debug "expire: deleted %d %s object(s)" done_ name;
          on_delete ~name ~deleted:done_;
          go done_ rest
    in
    go 0 keys

  let parse = History.parse ~versions_prefix:C.versions_prefix

  (* A folder's index is not one of its children, so no fold offers it, and it
     holds a copy of every manifest body in the folder: left behind, nothing
     else would ever reclaim it. Taken from the listing the walk already does,
     so only one that was really written is named.

     Errors propagate: a short list would leave part of the subtree undeleted
     while its parent marker goes. *)
  let collect_namespace folder_id acc =
    let indexes = ref [] in
    let+ children =
      Tree.fold_tree
        ~on_index:(fun key -> indexes := key :: !indexes)
        ~folder_id ~key:Lk.root
        (fun acc _key entry -> Lwt.return (entry.Inode_tree.bkey :: acc))
        acc
    in
    !indexes @ children

  (* One named folder whatever its age: {!expire} selects by cutoff, and that
     one cutoff governs versions and the journal too. *)
  let purge_trashed ?(on_delete = fun ~name:_ ~deleted:_ -> ()) ~path () =
    let* trash =
      B.list_prefix
        ~prefix:
          (Stored_key.to_string
             (Stored_key.trash_namespace ~prefix:C.domain_prefix))
        ()
    in
    let* found =
      Lwt_list.filter_map_s
        (fun (e : Backend.file_entry) ->
          (* As in {!expire}: an empty trash lists as its own directory key,
             which holds no marker and cannot be fetched on a filesystem
             store. *)
          if Stored_key.is_dir_key e.Backend.key then Lwt.return_none
          else
            let+ data = B.get ~key:e.Backend.key () in
            let data = Bigstring.to_string data in
            match
              (Folder.trash_path_of_string data, Folder.marker_of_string data)
            with
              | Some p, Some m when p = path -> Some (e.Backend.key, m)
              | _ -> None)
        trash
    in
    match found with
      | [] -> Lwt.return `Not_in_trash
      | (trash_key, m) :: _ ->
          Log.debug "purge: reclaiming trashed folder %s" m.Folder.name;
          let* subtree = collect_namespace m.Folder.id [] in
          (* The marker last: it is what names the subtree, so losing it first
             would strand every key under it with nothing pointing at them. *)
          let keys = subtree @ [trash_key] in
          let+ () = delete_all ~name:"trash" ~on_delete keys in
          `Purged (List.length keys)

  let expire ?(on_list = fun ~name:_ -> ())
      ?(on_scan = fun ~name:_ ~objects:_ -> ())
      ?(on_delete = fun ~name:_ ~deleted:_ -> ()) ~cutoff () =
    let cutoff_ns = Int64.of_float (cutoff *. 1e9) in
    (* Trashed folders go first, whole subtree at a time, so nothing in them
       counts as a reference by the time versions are partitioned. *)
    on_list ~name:"trash";
    let* trash =
      B.list_prefix
        ~prefix:
          (Stored_key.to_string
             (Stored_key.trash_namespace ~prefix:C.domain_prefix))
        ()
    in
    on_scan ~name:"trash" ~objects:(List.length trash);
    let* trash_keys =
      Lwt_list.fold_left_s
        (fun acc (e : Backend.file_entry) ->
          (* An empty trash lists as its own directory key, which holds no
             marker and cannot be fetched on a filesystem store. *)
          if
            Stored_key.is_dir_key e.Backend.key
            || e.Backend.last_modified >= cutoff
          then Lwt.return acc
          else
            let* data = B.get ~key:e.key () in
            match Folder.marker_of_string (Bigstring.to_string data) with
              | Some m ->
                  Log.debug "expire: reclaiming trashed folder %s" m.Folder.name;
                  let+ subtree = collect_namespace m.Folder.id [] in
                  (e.key :: subtree) @ acc
              | None -> Lwt.return acc)
        [] trash
    in
    let* () = delete_all ~name:"trash" ~on_delete trash_keys in
    on_list ~name:"versions";
    let* versions = B.list_prefix ~prefix:C.versions_prefix () in
    on_scan ~name:"versions" ~objects:(List.length versions);
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
    (* The version directories go after what they held. No-ops on S3, where no
       directory object exists. *)
    let* () = delete_all ~name:"versions" ~on_delete (List.map fst expired) in
    let survivor_rels = List.map snd surviving in
    let* () =
      List.sort_uniq compare (List.map snd expired)
      |> List.filter (fun rel -> not (List.mem rel survivor_rels))
      |> List.map (fun grouping ->
          History.versions_of ~versions_prefix:C.versions_prefix ~grouping)
      |> delete_all ~name:"version directories" ~on_delete
    in
    (* Age is the only safe criterion for the journal: the cursor says what was
       published, not what every client has applied, so entries above it are
       still owed to clients that are behind.

       The entry the cursor names is kept whatever its age, or a quiet domain
       whose last write predates the cutoff is left with a cursor pointing at
       nothing. *)
    let* cursor = Fs.fetch_cursor () in
    let cutoff_ms = Int64.of_float (cutoff *. 1000.) in
    on_list ~name:"journal";
    let* journal = B.list_prefix ~prefix:C.journal_prefix () in
    on_scan ~name:"journal" ~objects:(List.length journal);
    let stale =
      journal
      |> List.filter (fun (e : Backend.file_entry) ->
          match Journal.Entry_key.of_string (Stored_key.to_string e.key) with
            | None -> false
            | Some ek ->
                Journal.Entry_key.timestamp_ms ek < cutoff_ms
                && not
                     (Option.fold ~none:false
                        ~some:(fun c -> Journal.Entry_key.compare c ek = 0)
                        cursor))
      |> List.map (fun (e : Backend.file_entry) -> e.key)
    in
    let+ () = delete_all ~name:"journal" ~on_delete stale in
    {
      versions_deleted = List.length expired;
      journal_deleted = List.length stale;
    }
end
