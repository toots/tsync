open Tsync_core
open Tsync_store
open Tsync_remote

type counts = {
  trash_deleted : int;
  versions_deleted : int;
  journal_deleted : int;
  shares_deleted : int;
}

type report = {
  counts : counts;
  deleted : Key.t list;
  skipped_recent : Folder_id.t list;
  stopped : (Folder_id.t * string) list;
  unparseable_shares : Key.t list;
}

type purge = Purged of int | Not_in_trash | Live_elsewhere

module Make (C : Context.S) = struct
  module T = Tree.Make (C)

  let d = C.domain
  let store = C.store
  let anchor_leaf = Key.leaf (Key.anchor d Folder_id.root)

  let anchor_state id =
    match T.anchor id with
      | None -> Gc_plan.No_anchor
      | Some a when Folder.in_trash a -> In_trash
      | Some _ -> Live

  (* Filed markers only: a subfolder moved out of the trashed tree is not part
     of it, since its marker is disowned by its anchor. *)
  let rec subtree id depth =
    (Key.namespace d id, depth)
    :: List.concat_map
         (fun (e : Tree.entry) ->
           match e.body with Dir m -> subtree m.id (depth + 1) | File _ -> [])
         (T.children id)

  (* §4.2: deepest first, re-reading the trashed folder's anchor before each
     namespace; anchors stay as tombstones. *)
  let purge_folder ~apply ~delete id entries =
    let rec go n = function
      | [] ->
          delete entries;
          Ok n
      | ns :: rest ->
          if apply && anchor_state id = Live then
            Error "restored while it was being purged"
          else (
            let keys =
              List.filter_map
                (fun (e : Store.entry) ->
                  if Key.leaf e.key = anchor_leaf then None else Some e.key)
                (store.list_prefix ns)
            in
            delete keys;
            go (n + List.length keys) rest)
    in
    go 0 (Gc_plan.purge_order (subtree id 0))

  let by_folder () =
    let groups = Hashtbl.create 16 in
    List.iter
      (fun ((e : Store.entry), (m : Folder.marker), path) ->
        let l =
          Option.value ~default:[]
            (Hashtbl.find_opt groups (Folder_id.to_string m.id))
        in
        Hashtbl.replace groups (Folder_id.to_string m.id) ((m.id, e, path) :: l))
      (T.trash_entries ());
    Hashtbl.fold (fun _ l acc -> l :: acc) groups []

  let expire ?(apply = false) ?(now = Unix.gettimeofday ()) ~cutoff () =
    let deleted = ref [] in
    let delete keys =
      deleted := List.rev_append keys !deleted;
      if apply && keys <> [] then store.delete_multi keys
    in
    let count f =
      let before = List.length !deleted in
      f ();
      List.length !deleted - before
    in
    let skipped = ref [] and stopped = ref [] and unparseable = ref [] in
    let trash_deleted =
      count (fun () ->
          List.iter
            (fun group ->
              let id, _, _ = List.hd group in
              let entries =
                List.map
                  (fun (_, (e : Store.entry), _) -> (e.key, e.last_modified))
                  group
              in
              match Gc_plan.trash ~anchor:(anchor_state id) ~cutoff entries with
                | Delete_stale keys ->
                    List.iter
                      (fun k ->
                        Log.info "stale trash entry %s" (Key.to_string k))
                      keys;
                    delete keys
                | Skip_recent -> skipped := id :: !skipped
                | Refuse_live -> ()
                | Purge keys -> (
                    match purge_folder ~apply ~delete id keys with
                      | Ok _ -> ()
                      | Error reason -> stopped := (id, reason) :: !stopped))
            (by_folder ()))
    in
    let versions_deleted =
      count (fun () ->
          delete
            (Gc_plan.versions ~cutoff
               (List.map
                  (fun (e : Store.entry) -> e.key)
                  (store.list_prefix (Key.versions d)))))
    in
    let journal_deleted =
      count (fun () ->
          let journal = Tsync_sync.Journal.create d store in
          let cursor =
            match Tsync_sync.Journal.cursor_read journal with
              | `Key k -> Some k
              | `None -> None
              | `Unparsed body ->
                  Log.warn "the journal cursor does not parse: %S" body;
                  None
          in
          delete
            (Gc_plan.journal ~now ~horizon:Tsync_sync.Outbound.horizon ~cutoff
               ~cursor
               (Tsync_sync.Journal.list_entries journal)))
    in
    let shares_deleted =
      count (fun () ->
          let listing = store.list_prefix Key.shares in
          let artifact (e : Store.entry) =
            String.ends_with ~suffix:".data" (Key.leaf e.key)
          in
          List.iter
            (fun (e : Store.entry) ->
              if artifact e then (
                if e.last_modified < cutoff then delete [e.key])
              else (
                match store.get_opt e.key with
                  | None -> ()
                  | Some b -> (
                      match
                        Gc_plan.share ~domain:d ~now (Bigstring.to_string b)
                      with
                        | Expired ->
                            let token = Key.leaf e.key in
                            delete
                              (e.key
                              :: List.filter_map
                                   (fun (a : Store.entry) ->
                                     if
                                       Key.leaf a.key = token ^ ".data"
                                       && a.last_modified >= cutoff
                                     then Some a.key
                                     else None)
                                   listing)
                        | Unparseable -> unparseable := e.key :: !unparseable
                        | Kept | Other_domain -> ())))
            listing)
    in
    {
      counts =
        { trash_deleted; versions_deleted; journal_deleted; shares_deleted };
      deleted = List.rev !deleted;
      skipped_recent = !skipped;
      stopped = !stopped;
      unparseable_shares = !unparseable;
    }

  let purge ?(apply = false) path =
    let delete keys = if apply && keys <> [] then store.delete_multi keys in
    match List.filter (fun (_, _, p) -> p = Some path) (T.trash_entries ()) with
      | [] -> Not_in_trash
      | (_, (m : Folder.marker), _) :: _ -> (
          let all =
            List.concat_map
              (fun g ->
                List.filter_map
                  (fun (id, (e : Store.entry), _) ->
                    if Folder_id.equal id m.id then Some (e.key, e.last_modified)
                    else None)
                  g)
              (by_folder ())
          in
          match
            Gc_plan.trash ~anchor:(anchor_state m.id) ~cutoff:0. ~on_demand:true
              all
          with
            | Refuse_live -> Live_elsewhere
            | Purge keys -> (
                match purge_folder ~apply ~delete m.id keys with
                  | Ok n -> Purged n
                  | Error _ -> Live_elsewhere)
            | Delete_stale _ | Skip_recent -> Live_elsewhere)
end
