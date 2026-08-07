open Lwt.Syntax

type dest_stats = {
  name : string;
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

  let resync_to ?(on_copy = fun ~name:_ ~key:_ ~bytes:_ -> ()) src dst ~name
      entries =
    let+ results =
      Lwt_list.map_p
        (fun entry ->
          Lwt_bounded.use copy_pool (fun () ->
              let+ copied = sync_entry src dst entry in
              (match copied with
                | Some bytes -> on_copy ~name ~key:entry.Backend.key ~bytes
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
        { name; checked = List.length entries; copied = []; copied_bytes = 0 }
        results
    in
    { stats with copied = List.rev stats.copied }

  (* [source] names a member; the default is the first, which role order makes a
     main. Copies between the stores themselves rather than through {!Conf.store}
     — the point is to reach the ones the composite writes off the caller's path,
     or does not write at all. Additive only: a delete normally fans out to every
     store, and resync exists for those that were down, drifted, or were added
     later.

     Raises [Failure] when nothing has that name. *)
  let resync ?source ?(manifests_only = false) ?(on_scan = fun ~objects:_ -> ())
      ?(on_list = fun ~name:_ -> ()) ?on_copy () =
    let named name =
      match
        List.filter
          (fun (m : Backend.member) -> m.Backend.name = name)
          C.members
      with
        | [m] -> m
        | [] ->
            failwith
              (Printf.sprintf "no backend named %s (available: %s)" name
                 (String.concat ", "
                    (List.map (fun (m : Backend.member) -> m.name) C.members)))
        | _ ->
            failwith
              (Printf.sprintf
                 "backend name %s is ambiguous; set distinct \"name\" fields \
                  in the config"
                 name)
    in
    let src =
      match (source, C.members) with
        | Some name, _ -> named name
        | None, m :: _ -> m
        | None, [] -> failwith "no backends configured"
    in
    let* entries =
      source_entries ~manifests_only ~on_list src.Backend.backend
    in
    on_scan ~objects:(List.length entries);
    C.members
    |> List.filter (fun (m : Backend.member) -> m.Backend.name <> src.name)
    |> Lwt_list.map_s (fun (m : Backend.member) ->
        resync_to ?on_copy src.Backend.backend m.Backend.backend
          ~name:m.Backend.name entries)
end
