open Lwt.Syntax

type dest_stats = {
  index : int;
  checked : int;
  copied : string list;
  copied_bytes : int;
}

module Make (C : Conf.S) = struct
  (* Bounds concurrent HEAD/copy operations per destination. A copy holds the
     whole object body, so this follows [max_chunk_buffers] rather than the
     file-level [max_uploads]. *)
  let copy_pool = Lwt_bounded.create ~max:C.max_chunk_buffers ()

  (* Objects are content-addressed or immutable once written, so a size mismatch
     means the destination copy is corrupt. [None] when it was already
     correct. *)
  let sync_entry (module Src : Backend.S) (module Dst : Backend.S)
      (entry : Backend.file_entry) =
    let* head = Dst.head_opt ~key:entry.key () in
    let up_to_date =
      match head with
        | Some h -> Key.is_dir entry.key || h.Backend.size = entry.size
        | None -> false
    in
    if up_to_date then Lwt.return_none
    else if Key.is_dir entry.key then
      let+ () = Dst.put ~key:entry.key ~data:"" () in
      Some 0
    else
      let* data = Src.get ~key:entry.key () in
      let+ () = Dst.put ~key:entry.key ~data () in
      Some (String.length data)

  (* The chunk store is shared across domains on one bucket, and mirroring all of
     it is deliberate: chunks are content-addressed, so extra copies only help
     the other domains. *)
  let source_entries ?(manifests_only = false) ?(on_list = fun ~name:_ -> ())
      (module Src : Backend.S) =
    let prefixes =
      if manifests_only then [("manifests", C.domain_prefix)]
      else
        [
          ("manifests", C.domain_prefix);
          ("chunks", C.chunk_prefix);
          ("journal", C.journal_prefix);
          ("versions", C.versions_prefix);
        ]
    in
    let* per_prefix =
      Lwt_list.map_s
        (fun (name, prefix) ->
          on_list ~name;
          Src.list_prefix ~prefix ())
        prefixes
    in
    let+ cursor =
      if manifests_only then Lwt.return_none
      else Src.head_opt ~key:C.cursor_key ()
    in
    let entries =
      List.concat per_prefix @ match cursor with Some e -> [e] | None -> []
    in
    (* Listing order is backend-dependent. *)
    List.sort_uniq
      (fun (a : Backend.file_entry) (b : Backend.file_entry) ->
        compare a.key b.key)
      entries

  let resync_to ?(on_copy = fun ~index:_ ~key:_ ~bytes:_ -> ()) src dst ~index
      entries =
    let+ results =
      Lwt_list.map_p
        (fun entry ->
          Lwt_bounded.use copy_pool (fun () ->
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

  (* [source] is a position in [C.backends], 0 being the primary. Additive only:
     a delete normally fans out to every backend, and resync exists for backends
     that were down, drifted, or were added later. *)
  let resync ?(source = 0) ?(manifests_only = false)
      ?(on_scan = fun ~objects:_ -> ()) ?(on_list = fun ~name:_ -> ()) ?on_copy
      () =
    let src = List.nth C.backends source in
    let* entries = source_entries ~manifests_only ~on_list src in
    on_scan ~objects:(List.length entries);
    List.mapi (fun i b -> (i, b)) C.backends
    |> List.filter (fun (i, _) -> i <> source)
    |> Lwt_list.map_s (fun (index, dst) ->
        resync_to ?on_copy src dst ~index entries)
end
