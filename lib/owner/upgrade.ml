open Tsync_core
open Tsync_store

let trash = ".tsync-trash"

(* The parent an anchor body names, read as the journal protocol wrote it:
   the trash was a reserved id there. *)
let anchored_under body =
  match Yojson.Safe.from_string (Bigstring.to_string body) with
    | `Assoc f -> (
        match List.assoc_opt "parent" f with
          | Some (`String p) -> Some p
          | _ -> None)
    | _ | (exception _) -> None

let run ~out ~cancelled (dom : Tsync_domain.Domain.t) ~apply ~discard ~in_sync =
  let say fmt = Printf.ksprintf out fmt in
  let module C = (val Tsync_domain.Domain.context dom) in
  let d = dom.name and store = C.store in
  let name = Domain_name.to_string d in
  let local sub = List.fold_left Filename.concat dom.data_dir [sub; name] in
  let wal = local "journal-pending" and claims = local "claims-pending" in
  let mark = Filename.concat dom.data_dir ("last-sync-" ^ name) in
  let records dir =
    List.filter (fun n -> not (Names.is_temp_name n)) (Fs.readdir dir)
  in
  let unpublished = records wal in
  let staged =
    List.length
      (Tsync_checkout.Staged.edits
         (Tsync_checkout.Staged.create ~cache_root:dom.cache_root d))
  in
  let state = Tsync_sync.Sync_state.open_ ~data_dir:dom.data_dir d in
  (* With no before-value, a change this client holds alone would read as the
     main's own state at entry 0 and never be pushed. *)
  let not_in_sync =
    if not in_sync then None
    else if dom.lazy_tree then Some "a lazy tree keeps a position per folder"
    else if unpublished <> [] then Some "it has unpublished records"
    else if staged > 0 then Some "it has staged edits"
    else None
  in
  if not_in_sync <> None then (
    say "%s: --in-sync refused: %s" name (Option.get not_in_sync);
    1)
  else if unpublished <> [] && not discard then (
    say
      "%s: %d records of the previous version are not published. Start the \
       previous version and let it publish them, or pass --discard to lose \
       them (staged edits are kept either way)."
      name (List.length unpublished);
    1)
  else (
    let under sub =
      Key.prefix (Key.prefix_to_string (Key.domain_prefix d) ^ sub ^ "/")
    in
    let keys prefix =
      List.map
        (fun (e : Store.entry) -> e.key)
        (Cancel.race cancelled (fun () -> store.list_prefix prefix))
    in
    let journal = keys (under "journal") in
    let manifests = keys (Key.manifests d) in
    let namespace_of key = Key.parent_segment key in
    let anchor_leaf = Key.leaf (Key.anchor d Folder_id.root) in
    let parents = Hashtbl.create 256 in
    List.iter
      (fun key ->
        if Key.leaf key = anchor_leaf then
          Option.iter
            (fun body ->
              Option.iter
                (Hashtbl.replace parents (namespace_of key))
                (anchored_under body))
            (store.get_opt key))
      manifests;
    let rec in_trash seen id =
      id = trash
      || (not (List.mem id seen))
         &&
           match Hashtbl.find_opt parents id with
           | Some parent -> in_trash (id :: seen) parent
           | None -> false
    in
    let trashed =
      List.filter (fun key -> in_trash [] (namespace_of key)) manifests
    in
    let folders =
      List.length
        (List.sort_uniq String.compare
           (List.filter (( <> ) trash) (List.map namespace_of trashed)))
    in
    (* A cursor of the journal protocol holds an entry key, not a number. *)
    let cursor =
      match store.get_opt (Key.cursor d) with
        | Some b
          when int_of_string_opt (String.trim (Bigstring.to_string b)) = None ->
            [Key.cursor d]
        | _ -> []
    in
    say
      "%s: %d journal entries, %d objects of the folder trash and of the %d \
       folders in it%s"
      name (List.length journal) (List.length trashed) folders
      (if cursor = [] then "" else ", the journal's cursor");
    say "%s, here: %d WAL records, %d folder claims%s" name
      (List.length unpublished)
      (List.length (records claims))
      (if Fs.exists mark then ", the last-sync mark" else "");
    let seeded = in_sync && Tsync_sync.Sync_state.position state = None in
    if in_sync then
      say "%s, here: %s" name
        (if seeded then
           "starts at entry 0, taking the mirror for the tree as it stands"
         else "already has a position, which is kept");
    if not apply then (
      say "(dry run: nothing changed; --apply to act)";
      0)
    else (
      match
        Cancel.batches cancelled store.delete_multi (journal @ trashed @ cursor)
      with
        | `Cancelled ->
            say "cancelled: run it again to finish";
            1
        | `Done ->
            Fs.rm_rf wal;
            Fs.rm_rf claims;
            Fs.unlink_quiet mark;
            if seeded then Tsync_sync.Sync_state.set_position state 0;
            say "%s: done. Start the owner: it %s." name
              (if in_sync then "follows the log from entry 0"
               else "arrives by state");
            0))
