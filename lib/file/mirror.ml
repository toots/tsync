open Lwt.Syntax

type dest_stats = {
  index : int;
  checked : int;
  copied : string list;
  copied_bytes : int;
}

let is_marker key = String.length key > 0 && key.[String.length key - 1] = '/'

module Make (C : Conf.S) = struct
  (* Bounds concurrent HEAD/copy operations per destination. *)
  let copy_pool =
    Lwt_pool.create (max 1 C.max_uploads) (fun () -> Lwt.return_unit)

  (* Copy [entry] from [src] to [dst] when it is missing there or its size
     differs (objects are content-addressed or immutable-once-written, so a
     size mismatch means the destination copy is corrupt). Returns the bytes
     copied, or [None] when the destination was already correct. *)
  let sync_entry (module Src : Backend.S) (module Dst : Backend.S)
      (entry : Backend.file_entry) =
    let* head = Dst.head_opt ~key:entry.key () in
    let up_to_date =
      match head with
        | Some h -> is_marker entry.key || h.Backend.size = entry.size
        | None -> false
    in
    if up_to_date then Lwt.return_none
    else if is_marker entry.key then
      let+ () = Dst.put ~key:entry.key ~data:"" () in
      Some 0
    else
      let* data = Src.get ~key:entry.key () in
      let+ () = Dst.put ~key:entry.key ~data () in
      Some (String.length data)

  (* Everything the daemon writes for this domain. The chunk store is shared
     across domains on the same bucket; mirroring all of it is deliberate
     (chunks are content-addressed, extra copies only help other domains). *)
  let source_entries ?(manifests_only = false) (module Src : Backend.S) =
    let prefixes =
      if manifests_only then [C.domain_prefix]
      else
        [C.domain_prefix; C.chunk_prefix; C.journal_prefix; C.versions_prefix]
    in
    let* per_prefix =
      Lwt_list.map_s (fun prefix -> Src.list_all ~prefix ()) prefixes
    in
    let+ cursor =
      if manifests_only then Lwt.return_none
      else Src.head_opt ~key:C.cursor_key ()
    in
    let entries =
      List.concat per_prefix @ match cursor with Some e -> [e] | None -> []
    in
    (* Listing order is backend-dependent; sort for deterministic processing
       and reporting. *)
    List.sort_uniq
      (fun (a : Backend.file_entry) (b : Backend.file_entry) ->
        compare a.key b.key)
      entries

  let resync_to ?(on_copy = fun ~index:_ ~key:_ ~bytes:_ -> ()) src dst ~index
      entries =
    let+ results =
      Lwt_list.map_p
        (fun entry ->
          Lwt_pool.use copy_pool (fun () ->
              let+ copied = sync_entry src dst entry in
              (match copied with
                | Some bytes -> on_copy ~index ~key:entry.Backend.key ~bytes
                | None -> ());
              (entry.Backend.key, copied)))
        entries
    in
    let stats =
      List.fold_left
        (fun acc (key, copied) ->
          match copied with
            | None -> acc
            | Some bytes ->
                {
                  acc with
                  copied = key :: acc.copied;
                  copied_bytes = acc.copied_bytes + bytes;
                })
        { index; checked = List.length entries; copied = []; copied_bytes = 0 }
        results
    in
    { stats with copied = List.rev stats.copied }

  (* Bring every other configured backend up to date with the backend at
     [source] (position in [C.backends], 0 = primary): copy any object that is
     missing or size-mismatched there. Additive only — objects deleted on the
     source are not deleted on the destinations (deletes normally fan out to
     all backends; resync is for backends that were down, drifted or were
     added later). *)
  let resync ?(source = 0) ?(manifests_only = false)
      ?(on_scan = fun ~objects:_ -> ()) ?on_copy () =
    let src = List.nth C.backends source in
    let* entries = source_entries ~manifests_only src in
    on_scan ~objects:(List.length entries);
    List.mapi (fun i b -> (i, b)) C.backends
    |> List.filter (fun (i, _) -> i <> source)
    |> Lwt_list.map_s (fun (index, dst) ->
        resync_to ?on_copy src dst ~index entries)
end
