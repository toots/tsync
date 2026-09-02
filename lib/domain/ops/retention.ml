type stats = { versions_deleted : int; journal_deleted : int }
type restored = Restored | Not_in_trash | Parent_unknown
type deleted = { path : string; latest : int64; versions : int }

module Over
    (Io : Io.S)
    (Inode_layout : Layout.OVER with type 'a io := 'a Io.t)
    (Manifests : Store.OVER with type 'a io := 'a Io.t)
    (Folder_ids : Folder_ids.S with type 'a io := 'a Io.t)
    (Tree : Inode_tree.OVER with type 'a io := 'a Io.t)
    (Cursor_of : File_store.OVER with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module Lk = Logical_key.Make (C)
    module L = Inode_layout.Make (C)
    module St = Manifests.Make (C) (L)
    module Cursor = Cursor_of.Make (C)
    module Tree = Tree.Make (C)
    module B = (val C.store : C.Store)

    let parse = History.parse ~versions_prefix:C.versions_prefix

    (* Every marker in the trash with its body. An empty trash lists as its own
       directory key, which holds no marker and cannot be fetched on a
       filesystem store; [keep] is asked before the body is, so a pass that
       only wants old markers does not read the rest. *)
    let trash_markers ?(keep = fun (_ : Backend.file_entry) -> true) () =
      let* entries =
        B.list_prefix
          ~prefix:
            (Stored_key.to_string
               (Stored_key.trash_namespace ~prefix:C.domain_prefix))
          ()
      in
      filter_map_s
        (fun (e : Backend.file_entry) ->
          if Stored_key.is_dir_key e.Backend.key || not (keep e) then
            Io.return None
          else
            let+ data = B.get ~key:e.Backend.key () in
            Some (e, Bigstring.to_string data))
        entries

    let trashed () =
      let+ markers = trash_markers () in
      List.filter_map
        (fun (_, body) -> Folder.trash_path_of_string body)
        markers

    let find_trashed path =
      let+ markers = trash_markers () in
      List.find_map
        (fun ((e : Backend.file_entry), body) ->
          match
            (Folder.trash_path_of_string body, Folder.marker_of_string body)
          with
            | Some p, Some m when p = path -> Some (e.Backend.key, m)
            | _ -> None)
        markers

    let restore path =
      let* found = find_trashed path in
      match found with
        | None -> Io.return Not_in_trash
        | Some (trash_key, m) -> (
            (* Where it goes back is filed under its parent's namespace, so a
               client that has never resolved the parent has no key to write and
               must sync before it can put anything back. *)
            let* new_key = L.folder_marker_key (Lk.dir path) in
            match new_key with
              | None -> Io.return Parent_unknown
              | Some new_key ->
                  (* O(1): the subtree is untouched. The local mirror copy is
                     rebuilt by a later full sync. *)
                  let marker =
                    Folder.marker_to_string
                      { Folder.name = m.Folder.name; id = m.Folder.id }
                  in
                  let* () = St.put_raw ~bkey:new_key ~data:marker in
                  let+ () = St.delete_raw ~bkey:trash_key in
                  Restored)

    (* Version keys are hashed, so the real name is read out of the body a version
       kept rather than derived from the key. *)
    let recorded_name key fallback =
      Io.catch
        (fun () ->
          let+ data = B.get ~key () in
          match Manifest.of_string (Bigstring.to_string data) with
            | m -> Manifest.recorded_name m
            | exception _ -> fallback)
        (fun _ -> Io.return fallback)

    let live grouping =
      let+ head =
        B.head_opt
          ~key:(History.manifest_of ~domain_prefix:C.domain_prefix ~grouping)
          ()
      in
      head <> None

    let deleted_in_folder key =
      (* Versions of the files in a folder share the folder's id. *)
      let* fid =
        Folder_ids.ensure_id ~cache_root:C.cache_root ~domain_name:C.domain_name
          key
      in
      let* entries =
        B.list_prefix
          ~prefix:
            (Stored_key.to_string
               (History.folder_versions ~versions_prefix:C.versions_prefix
                  ~folder_id:fid))
          ()
      in
      let seen = Hashtbl.create 16 in
      filter_map_s
        (fun (e : Backend.file_entry) ->
          match parse e.Backend.key with
            | Some (hrel, _) when not (Hashtbl.mem seen hrel) ->
                Hashtbl.add seen hrel ();
                let* alive = live hrel in
                if alive then Io.return None
                else
                  let+ name = recorded_name e.Backend.key hrel in
                  Some name
            | _ -> Io.return None)
        entries

    let deleted_in_domain () =
      let latest = Hashtbl.create 64
      and count = Hashtbl.create 64
      and sample = Hashtbl.create 64 in
      let* entries = B.list_prefix ~prefix:C.versions_prefix () in
      List.iter
        (fun (e : Backend.file_entry) ->
          match parse e.Backend.key with
            | Some (rel, ts) ->
                let ts = Int64.of_string ts in
                let best =
                  Option.value ~default:0L (Hashtbl.find_opt latest rel)
                in
                if Int64.compare ts best > 0 then Hashtbl.replace latest rel ts;
                Hashtbl.replace sample rel e.Backend.key;
                Hashtbl.replace count rel
                  (1 + Option.value ~default:0 (Hashtbl.find_opt count rel))
            | None -> ())
        entries;
      Hashtbl.fold
        (fun rel ts acc ->
          let* acc = acc in
          let* alive = live rel in
          if alive then Io.return acc
          else
            let+ path = recorded_name (Hashtbl.find sample rel) rel in
            {
              path;
              latest = ts;
              versions = Option.value ~default:1 (Hashtbl.find_opt count rel);
            }
            :: acc)
        latest (Io.return [])

    let delete_all ~name ~on_delete keys =
      let rec go done_ = function
        | [] -> Io.return ()
        | keys ->
            let batch, rest = Batch.take Batch.per_delete keys in
            let* () = B.delete_multi batch in
            let done_ = done_ + List.length batch in
            Log.debug "expire: deleted %d %s object(s)" done_ name;
            on_delete ~name ~deleted:done_;
            go done_ rest
      in
      go 0 keys

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
          (fun acc _key entry -> Io.return (entry.Inode_tree.bkey :: acc))
          acc
      in
      !indexes @ children

    (* One named folder whatever its age: {!expire} selects by cutoff, and that
       one cutoff governs versions and the journal too. *)
    let purge_trashed ?(on_delete = fun ~name:_ ~deleted:_ -> ()) ~path () =
      let* found = find_trashed path in
      match found with
        | None -> Io.return `Not_in_trash
        | Some (trash_key, m) ->
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
        trash_markers ~keep:(fun e -> e.Backend.last_modified < cutoff) ()
      in
      on_scan ~name:"trash" ~objects:(List.length trash);
      let* trash_keys =
        fold_left_s
          (fun acc ((e : Backend.file_entry), body) ->
            match Folder.marker_of_string body with
              | Some m ->
                  Log.debug "expire: reclaiming trashed folder %s" m.Folder.name;
                  let+ subtree = collect_namespace m.Folder.id [] in
                  (e.key :: subtree) @ acc
              | None -> Io.return acc)
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
      let* cursor = Cursor.fetch_cursor () in
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
end
