open Tsync_core
open Tsync_store
open Tsync_remote

type counts = {
  versions_deleted : int;
  log_deleted : int;
  shares_deleted : int;
}

type report = {
  counts : counts;
  deleted : Key.t list;
  unparseable_shares : Key.t list;
  cancelled : bool;
}

module Make (C : Context.S) = struct
  let d = C.domain
  let store = C.store

  (* §4.1: a filesystem store keeps the directories of a group whose versions
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

  (* §4.3: each member holding shares, since a share may sit on a copy alone;
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
    Narrate.say nr "expiring %s: versions, log and shares older than %s%s"
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
    let unparseable = ref [] in
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
    let log_deleted =
      count (fun () ->
          let log = Log_store.create d store in
          let tree_head = Log_store.tree_head log in
          let listed prefix =
            Cancel.race cancelled (fun () -> store.list_prefix prefix)
          in
          let entries = listed (Key.log d) in
          let doomed =
            Gc_plan.log ~now ~retention:Log_store.retention ~tree_head
              (List.map
                 (fun (e : Store.entry) -> (e.key, e.last_modified))
                 entries)
          in
          Narrate.say nr
            "  log: %d of %s at or below the tree head (%d) and older than %s"
            (List.length doomed)
            (Narrate.count ~plural:"entries are" (List.length entries)
               "entry is")
            tree_head
            (Narrate.date (now -. Log_store.retention));
          delete doomed;
          delete
            (Gc_plan.takeovers ~tree_head
               (List.map
                  (fun (e : Store.entry) -> e.key)
                  (listed (Key.takeovers d)))))
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
      counts = { versions_deleted; log_deleted; shares_deleted };
      deleted = List.rev !deleted;
      unparseable_shares = !unparseable;
      cancelled = cancelled ();
    }
end
