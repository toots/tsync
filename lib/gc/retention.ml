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
  cancelled : bool;
}

type purge = Purged of int | Not_in_trash | Live_elsewhere | Stopped of string

module Make (C : Context.S) = struct
  module T = Tree.Make (C)

  let d = C.domain
  let store = C.store
  let anchor_leaf = Key.leaf (Key.anchor d Folder_id.root)

  let anchor_state id : Gc_plan.anchor =
    match T.trash_state id with
      | `No_anchor -> No_anchor
      | `In_trash -> In_trash
      | `Live -> Live

  let entries_of (f : T.trashed) =
    List.map (fun (e : Store.entry) -> (e.key, e.last_modified)) f.entries

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
  let purge_folder ~apply ~delete ~cancelled id entries =
    let rec go n = function
      | [] ->
          delete entries;
          Ok n
      | ns :: rest ->
          if apply && anchor_state id = Live then
            Error "restored while it was being purged"
          else if cancelled () then Error "cancelled"
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

  (* §4.3: a filesystem store keeps the directories of a group whose versions
     all expired; a snapshot racing the removal retries its write once. *)
  let remove_empty_groups keys =
    let rmdir p = try Unix.rmdir p with Unix.Unix_error _ -> () in
    List.iter
      (fun (m : Composite.member) ->
        Option.iter
          (fun root ->
            List.sort_uniq String.compare
              (List.map
                 (fun k -> Filename.dirname (Local_path.path root k))
                 keys)
            |> List.iter (fun group ->
                rmdir group;
                rmdir (Filename.dirname group)))
          m.store.local_path)
      (Composite.members C.composite)

  (* §4.5: each member holding shares, since a share may sit on a copy alone;
     copies behind the write guard, archives never. *)
  let shares_on ~apply ~cancelled ~now ~cutoff (m : Composite.member) =
    match
      if m.role <> Main then Composite.guard C.composite m "expire shares"
    with
      | exception ((Stop.Stopping | Rt.Cancelled) as e) -> raise e
      | exception e -> Error (Printexc.to_string e)
      | () ->
          let st = m.store in
          let listing =
            Cancel.race cancelled (fun () -> st.list_prefix Key.shares)
          in
          let artifact (e : Store.entry) =
            String.ends_with ~suffix:".data" (Key.leaf e.key)
          in
          let listed = Hashtbl.create (List.length listing) in
          List.iter
            (fun (e : Store.entry) -> Hashtbl.replace listed e.key ())
            listing;
          let bad = ref [] in
          let doomed =
            List.concat_map
              (fun (e : Store.entry) ->
                if artifact e then
                  if e.last_modified < cutoff then [e.key] else []
                else (
                  match Key.preview_token (Key.to_string e.key) with
                    | Some token ->
                        if Hashtbl.mem listed (Option.get (Key.share token))
                        then []
                        else [e.key]
                    | None -> (
                        Cancel.check cancelled;
                        match st.get_opt e.key with
                          | None -> []
                          | Some b -> (
                              match
                                Gc_plan.share ~domain:d ~now
                                  (Bigstring.to_string b)
                              with
                                | Expired ->
                                    let token = Key.leaf e.key in
                                    e.key
                                    :: List.filter_map
                                         (fun (a : Store.entry) ->
                                           if
                                             Key.leaf a.key = token ^ ".data"
                                             && a.last_modified >= cutoff
                                             || Key.leaf a.key = token ^ ".jpg"
                                           then Some a.key
                                           else None)
                                         listing
                                | Unparseable ->
                                    bad := e.key :: !bad;
                                    []
                                | Kept | Other_domain -> []))))
              listing
          in
          let deleted = ref [] in
          if apply then
            ignore
              (Cancel.batches cancelled
                 (fun batch ->
                   st.delete_multi batch;
                   deleted := List.rev_append batch !deleted)
                 doomed)
          else deleted := List.rev doomed;
          Ok (List.rev !deleted, !bad)

  let expire ?(narrate = Narrate.none) ?(apply = false)
      ?(cancelled = Fun.const false) ?(now = Unix.gettimeofday ()) ~cutoff () =
    let nr = narrate in
    Narrate.say nr
      "expiring %s: trash, versions, journal and shares older than %s%s"
      (Domain_name.to_string d) (Narrate.date cutoff)
      (if apply then "" else " (dry run: nothing is deleted)");
    let deleted = ref [] in
    let delete keys =
      if not apply then deleted := List.rev_append keys !deleted
      else
        ignore
          (Cancel.batches cancelled
             (fun batch ->
               store.delete_multi batch;
               deleted := List.rev_append batch !deleted)
             keys)
    in
    (* A cancelled expiry skips what is left, phase by phase. *)
    let count f =
      let before = List.length !deleted in
      if not (cancelled ()) then f ();
      List.length !deleted - before
    in
    let skipped = ref [] and stopped = ref [] and unparseable = ref [] in
    let trash_deleted =
      count (fun () ->
          let folders = T.trashed () in
          Narrate.say nr "  trash: %s"
            (Narrate.count (List.length folders) "trashed folder");
          let total = List.length folders in
          List.iteri
            (fun i (f : T.trashed) ->
              Narrate.progress nr
                ~fraction:(float i /. float total)
                "trash: %d of %d trashed folders" (i + 1) total;
              if not (cancelled ()) then (
                let id = f.id and newest = f.latest in
                let name = Option.value ~default:f.name f.path in
                match
                  Gc_plan.trash ~anchor:(anchor_state id) ~cutoff (entries_of f)
                with
                  | Delete_stale keys ->
                      Narrate.say nr "    %s: the folder is live again; %s" name
                        (if keys = [] then
                           "its trash entries are younger than the cutoff and \
                            stay"
                         else
                           Printf.sprintf "%s %s, the folder stays"
                             (if apply then "deleting" else "would delete")
                             (Narrate.count ~plural:"stale trash entries"
                                (List.length keys) "stale trash entry"));
                      delete keys
                  | Skip_recent ->
                      Narrate.say nr "    %s: kept, trashed again on %s" name
                        (Narrate.date newest);
                      skipped := id :: !skipped
                  | Refuse_live -> ()
                  | Purge keys -> (
                      match purge_folder ~apply ~delete ~cancelled id keys with
                        | Ok n ->
                            Narrate.say nr
                              "    %s: %s (trashed on %s): %s, deepest folder \
                               first, then %s"
                              name
                              (if apply then "purged" else "would be purged")
                              (Narrate.date newest) (Narrate.count n "object")
                              (Narrate.count ~plural:"trash entries"
                                 (List.length keys) "trash entry")
                        | Error reason ->
                            Narrate.say nr "    %s: purge stopped: %s" name
                              reason;
                            stopped := (id, reason) :: !stopped)))
            folders)
    in
    let versions_deleted =
      count (fun () ->
          let expired =
            Gc_plan.versions ~cutoff
              (List.map
                 (fun (e : Store.entry) -> e.key)
                 (Cancel.race cancelled (fun () ->
                      store.list_prefix (Key.versions d))))
          in
          Narrate.say nr "  versions: %s older than %s"
            (Narrate.count (List.length expired) "version")
            (Narrate.date cutoff);
          delete expired;
          if apply then remove_empty_groups expired)
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
          let entries =
            Cancel.race cancelled (fun () ->
                Tsync_sync.Journal.list_entries journal)
          in
          let doomed =
            Gc_plan.journal ~now ~horizon:Tsync_sync.Outbound.horizon ~cutoff
              ~cursor entries
          in
          Narrate.say nr
            "  journal: %d of %s older than %s and than the retention horizon \
             (%s)%s"
            (List.length doomed)
            (Narrate.count ~plural:"entries are" (List.length entries)
               "entry is")
            (Narrate.date cutoff)
            (Narrate.date (now -. Tsync_sync.Outbound.horizon))
            (if cursor = None then "" else "; the cursor's entry is kept");
          delete doomed)
    in
    let shares_deleted =
      count (fun () ->
          let seen = Hashtbl.create 16 in
          List.iter
            (fun (m : Composite.member) ->
              if not (cancelled ()) then (
                match shares_on ~apply ~cancelled ~now ~cutoff m with
                  | Error reason ->
                      Log.warn "shares on %s not expired: %s" m.name reason
                  | Ok (keys, bad) ->
                      Narrate.say nr "  shares on %s: %s and stale artifacts%s"
                        m.name
                        (Narrate.count (List.length keys) "expired share")
                        (if bad = [] then ""
                         else
                           Printf.sprintf "; %d unparseable, left in place"
                             (List.length bad));
                      List.iter
                        (fun k ->
                          if not (Hashtbl.mem seen k) then (
                            Hashtbl.replace seen k ();
                            deleted := k :: !deleted))
                        keys;
                      List.iter
                        (fun k ->
                          if not (List.exists (Key.equal k) !unparseable) then
                            unparseable := k :: !unparseable)
                        bad))
            (List.filter
               (fun (m : Composite.member) -> m.role <> Read_only)
               (Composite.members C.composite)))
    in
    {
      counts =
        { trash_deleted; versions_deleted; journal_deleted; shares_deleted };
      deleted = List.rev !deleted;
      skipped_recent = !skipped;
      stopped = !stopped;
      unparseable_shares = !unparseable;
      cancelled = cancelled ();
    }

  let purge ?(narrate = Narrate.none) ?(apply = false)
      ?(cancelled = Fun.const false) path =
    let nr = narrate in
    let delete keys =
      if apply then ignore (Cancel.batches cancelled store.delete_multi keys)
    in
    match
      List.find_opt (fun (f : T.trashed) -> f.path = Some path) (T.trashed ())
    with
      | None -> Not_in_trash
      | Some f -> (
          match
            Gc_plan.trash ~anchor:(anchor_state f.id) ~cutoff:0. ~on_demand:true
              (entries_of f)
          with
            | Refuse_live ->
                Narrate.say nr
                  "%s: its folder is live again elsewhere; nothing is purged"
                  path;
                Live_elsewhere
            | Purge keys -> (
                Narrate.say nr
                  "%s: purging its subtree deepest folder first, re-checking \
                   before each folder that it is still in the trash%s"
                  path
                  (if apply then "" else " (dry run: nothing is deleted)");
                match purge_folder ~apply ~delete ~cancelled f.id keys with
                  | Ok n ->
                      Narrate.say nr "  %s, then %s" (Narrate.count n "object")
                        (Narrate.count ~plural:"trash entries"
                           (List.length keys) "trash entry");
                      Purged n
                  | Error reason ->
                      Narrate.say nr "  stopped: %s" reason;
                      Stopped reason)
            | Delete_stale _ | Skip_recent -> Live_elsewhere)
end
