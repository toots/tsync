open Lwt.Syntax

type dest_stats = {
  name : string;
  checked : int;
  copied : string list;
  copied_bytes : int;
}

module Make (C : Conf.S) = struct
  module Space = Chunk_space.Make (C)
  module Tree = Inode_tree.Make (C)

  (* Bounds concurrent HEAD/copy operations per destination. A copy holds the
     whole object body, so this follows [max_chunk_buffers] rather than the
     file-level [max_uploads]. *)
  let copy_pool = Lwt_bounded.create ~max:C.max_chunk_buffers ()

  (* Objects are content-addressed or immutable once written, so a size mismatch
     means the destination copy is corrupt. [None] when it was already correct;
     otherwise what was wrong with it, which is worth carrying to the caller. *)
  let sync_entry (module Src : Backend.S) (module Dst : Backend.S)
      (entry : Backend.file_entry) =
    let* head = Dst.head_opt ~key:entry.key () in
    let* reason =
      match head with
        | None -> Lwt.return_some `Missing
        | Some h ->
            if Key.is_dir entry.key then Lwt.return_none
            else if h.Backend.size <> entry.size then
              Lwt.return_some `Wrong_size
            else Lwt.return_none
    in
    match reason with
      | None -> Lwt.return_none
      | Some reason ->
          if Key.is_dir entry.key then
            let+ () = Dst.put ~key:entry.key ~data:"" () in
            Some (reason, 0)
          else
            let* data = Src.get ~key:entry.key () in
            let+ () = Dst.put ~key:entry.key ~data () in
            Some (reason, String.length data)

  let dedup_entries entries =
    (* Listing order is backend-dependent. *)
    List.sort_uniq
      (fun (a : Backend.file_entry) (b : Backend.file_entry) ->
        compare a.key b.key)
      entries

  (* The chunk store is shared across domains on one bucket, and mirroring all of
     it is deliberate: chunks are content-addressed, so extra copies only help
     the other domains. *)
  let namespace_entries ~manifests_only ~on_list (module Src : Backend.S) =
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
          on_list ~name:("listing " ^ name);
          Src.list_prefix ~prefix ())
        prefixes
    in
    let+ cursor =
      if manifests_only then Lwt.return_none
      else Src.head_opt ~key:C.cursor_key ()
    in
    dedup_entries
      (List.concat per_prefix @ match cursor with Some e -> [e] | None -> [])

  (* [rel] itself and everything under it. *)
  let within ~rel path =
    rel = "" || path = rel || String.starts_with ~prefix:(rel ^ "/") path

  (* A folder [rel] sits inside: descended into, but nothing of its own is
     taken. *)
  let holds ~rel path = String.starts_with ~prefix:(path ^ "/") rel

  let chunk_keys (m : Manifest.t) =
    let table = m.Manifest.chunks in
    List.init (Chunk_table.count table) (fun i ->
        Space.key (Chunk_table.key table i))

  (* Only the folders [rel] runs through or lives in are descended into, so
     scoping to one folder costs its own subtree rather than the whole tree. A
     file brings the chunks it names: manifests alone would copy a listing the
     far side cannot read a byte of.

     Journal, versions and cursor are left out — they describe the domain, not
     this subtree, and copying part of a journal would state a history that never
     happened. *)
  let path_keys ~rel =
    let rec walk folder_id here acc =
      let* entries = Tree.children ~folder_id () in
      Lwt_list.fold_left_s
        (fun acc (entry : Inode_tree.entry) ->
          match entry.Inode_tree.body with
            | Inode_tree.Dir m ->
                let path = Key.join here m.Folder.name in
                if within ~rel path then
                  walk m.Folder.id path (entry.Inode_tree.bkey :: acc)
                else if holds ~rel path then walk m.Folder.id path acc
                else Lwt.return acc
            | Inode_tree.File m ->
                let path = Key.join here (Manifest.recorded_name m) in
                if within ~rel path then
                  Lwt.return (chunk_keys m @ (entry.Inode_tree.bkey :: acc))
                else Lwt.return acc)
        acc entries
    in
    let+ keys = walk Folder.root_id "" [] in
    List.sort_uniq compare keys

  (* This command copies a full backend onto a partial one, so an object the
     source cannot produce is the source being wrong, not the scope. *)
  let path_entries ~rel ~src_name ~on_list (module Src : Backend.S) =
    on_list ~name:(Printf.sprintf "walking the tree under %s" rel);
    let* keys = path_keys ~rel in
    on_list
      ~name:
        (Printf.sprintf "sizing %d object%s on %s" (List.length keys)
           (if List.length keys = 1 then "" else "s")
           src_name);
    let+ entries =
      Lwt_list.map_p
        (fun key ->
          Lwt_bounded.use copy_pool (fun () ->
              let+ head = Src.head_opt ~key () in
              match head with
                | Some e -> e
                | None ->
                    failwith
                      (Printf.sprintf "%s is missing from source %s" key
                         src_name)))
        keys
    in
    dedup_entries entries

  let resync_to ?(on_copy = fun ~name:_ ~key:_ ~reason:_ ~bytes:_ -> ()) src dst
      ~name entries =
    let+ results =
      Lwt_list.map_p
        (fun entry ->
          Lwt_bounded.use copy_pool (fun () ->
              let+ copied = sync_entry src dst entry in
              (match copied with
                | Some (reason, bytes) ->
                    on_copy ~name ~key:entry.Backend.key ~reason ~bytes
                | None -> ());
              (entry.Backend.key, copied)))
        entries
    in
    let stats =
      List.fold_left
        (fun acc (key, copied) ->
          match copied with
            | None -> acc
            | Some (_, bytes) ->
                {
                  acc with
                  copied = key :: acc.copied;
                  copied_bytes = acc.copied_bytes + bytes;
                })
        { name; checked = List.length entries; copied = []; copied_bytes = 0 }
        results
    in
    { stats with copied = List.rev stats.copied }

  (* Copies between the stores themselves rather than through {!Conf.store}: the
     point is to reach the ones the composite writes off the caller's path, or
     does not write at all. Raises [Failure] when nothing has that name. *)
  let resync ?source ?(scope = `All) ?(on_scan = fun ~objects:_ -> ())
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
    (* A collection in progress leaves the chunk prefix holding only what has
       been marked so far, so listing it would copy a partial chunk set to every
       target and call it a resync. *)
    let* () =
      let* run = Space.read_run () in
      match (run, scope) with
        | None, _ | Some _, `Manifests -> Lwt.return_unit
        | Some r, (`All | `Path _) ->
            failwith
              (Printf.sprintf
                 "%s is being collected (%s, started %.0fs ago), so its chunks \
                  are only partly under the usual prefix. Let tsync gc finish, \
                  or stop it with tsync gc --abort, then resync."
                 C.domain_name
                 (Chunk_space.string_of_phase r.Chunk_space.phase)
                 (Unix.gettimeofday () -. r.Chunk_space.started))
    in
    let* entries =
      match scope with
        | `All -> namespace_entries ~manifests_only:false ~on_list src.backend
        | `Manifests ->
            namespace_entries ~manifests_only:true ~on_list src.backend
        | `Path rel ->
            path_entries ~rel ~src_name:src.name ~on_list src.Backend.backend
    in
    on_scan ~objects:(List.length entries);
    C.members
    |> List.filter (fun (m : Backend.member) -> m.Backend.name <> src.name)
    |> Lwt_list.map_s (fun (m : Backend.member) ->
        resync_to ?on_copy src.Backend.backend m.Backend.backend
          ~name:m.Backend.name entries)
end
