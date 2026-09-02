module type S = sig
  type 'a io

  val marker_name : string

  val ensure_id :
    cache_root:string -> domain_name:string -> Logical_key.t -> string io

  val lookup_id :
    cache_root:string -> domain_name:string -> Logical_key.t -> string option io

  val lookup_id_removed :
    cache_root:string -> domain_name:string -> Logical_key.t -> string option io

  val ref_of_key :
    cache_root:string ->
    domain_name:string ->
    Logical_key.t ->
    Item_ref.t option io

  val write :
    cache_root:string ->
    domain_name:string ->
    Logical_key.t ->
    Folder.marker ->
    unit io

  val key_of_id :
    cache_root:string ->
    domain_name:string ->
    root:Logical_key.t ->
    string ->
    Logical_key.t option io

  val reparent :
    cache_root:string -> domain_name:string -> Logical_key.t -> unit io

  val rebuild : cache_root:string -> domain_name:string -> unit io
end

module Over (Io : Io.S) (F : Fs.S with type 'a io := 'a Io.t) = struct
  open Io_syntax.Make (Io)

  let marker_name = Stored_key.folder_marker_leaf

  (* Keyed by the folder itself: where its marker sits, what it is called and
     which folder holds it are all questions the key answers. *)
  let dir_of = Cache_layout.manifest_path

  let marker_path ~cache_root ~domain_name key =
    Filename.concat (dir_of ~cache_root ~domain_name key) marker_name

  let read ~cache_root ~domain_name key =
    let+ s = F.read_file_opt (marker_path ~cache_root ~domain_name key) in
    Option.bind s Folder.marker_of_string

  let index_path ~cache_root ~domain_name id =
    Filename.concat (Cache_layout.folders_dir ~cache_root domain_name) id

  (* An op is described after the mirror has applied it, and a removal takes the
     marker its id was read from — so a folder's id has to outlive the folder for
     the ops under it to stay nameable. Kept beside the id index, which outlives
     it for the same reason, and on disk because the process that applies an
     entry is not the one that describes it. *)
  let by_path_path ~cache_root ~domain_name key =
    Filename.concat
      (Filename.concat
         (Cache_layout.folders_dir ~cache_root domain_name)
         "by-path")
      (Digest.to_hex (Digest.string (Logical_key.to_string key)))

  type entry = { parent : string; name : string }

  let entry_to_string { parent; name } =
    Yojson.Basic.to_string
      (`Assoc [("parent", `String parent); ("name", `String name)])

  let entry_of_string data =
    match Yojson.Basic.from_string data with
      | `Assoc fields -> (
          match
            (List.assoc_opt "parent" fields, List.assoc_opt "name" fields)
          with
            | Some (`String parent), Some (`String name) ->
                Some { parent; name }
            | _ -> None)
      | _ | (exception _) -> None

  let read_entry ~cache_root ~domain_name id =
    let+ s = F.read_file_opt (index_path ~cache_root ~domain_name id) in
    Option.bind s entry_of_string

  let write_entry ~cache_root ~domain_name ~id entry =
    let path = index_path ~cache_root ~domain_name id in
    let* () = F.ensure_parent path in
    F.atomic_write path (entry_to_string entry)

  (* The name comes from where the folder actually sits, not from the marker being
     written: a marker that travelled with a renamed directory still carries the old
     leaf, and the index has to spell the path back out. *)
  let rec write ~cache_root ~domain_name key (m : Folder.marker) =
    let dir = dir_of ~cache_root ~domain_name key in
    let* () = F.mkdir_p dir in
    let path = Filename.concat dir marker_name in
    let* () = F.atomic_write path (Folder.marker_to_string m) in
    let* () =
      let p = by_path_path ~cache_root ~domain_name key in
      let* () = F.ensure_parent p in
      F.atomic_write p m.Folder.id
    in
    if Logical_key.is_root key then return_unit
    else
      let* parent =
        ensure_id ~cache_root ~domain_name (Logical_key.parent key)
      in
      write_entry ~cache_root ~domain_name ~id:m.Folder.id
        { parent; name = Logical_key.leaf key }

  (* Mints and persists a marker, so this is for the write paths only. *)
  and ensure_id ~cache_root ~domain_name key =
    if Logical_key.is_root key then Io.return Stored_key.root_id
    else
      let* existing = read ~cache_root ~domain_name key in
      match existing with
        | Some m -> Io.return m.Folder.id
        | None ->
            let m =
              { Folder.name = Logical_key.leaf key; id = Stored_key.new_id () }
            in
            let+ () = write ~cache_root ~domain_name key m in
            m.Folder.id

  (* What a read must use: minting here would persist a marker that re-creates the
     local directory, which is how a deleted folder comes back from a stat. *)
  let lookup_id ~cache_root ~domain_name key =
    if Logical_key.is_root key then return_some Stored_key.root_id
    else
      let+ existing = read ~cache_root ~domain_name key in
      Option.map (fun m -> m.Folder.id) existing

  (* Describing a removal is the one read that must answer for a folder the
     mirror has already dropped, and it names what is going away rather than
     resolving anything a caller could still reach. *)
  let lookup_id_removed ~cache_root ~domain_name key =
    let* live = lookup_id ~cache_root ~domain_name key in
    match live with
      | Some id -> return_some id
      | None ->
          let+ kept =
            F.read_file_opt (by_path_path ~cache_root ~domain_name key)
          in
          Option.map String.trim kept

  (* Only a directory has a marker, so finding one is what says the key names a
     folder rather than a file — no stat, and no caller left to guess the kind.

     The empty path is the domain root whichever kind it was built as, which is
     what lets a caller holding a path build the key without deciding first. *)
  let ref_of_key ~cache_root ~domain_name key =
    if Logical_key.path key = "" then return_some `Root
    else
      let* own = lookup_id ~cache_root ~domain_name key in
      match own with
        | Some id -> return_some (`Dir id)
        | None ->
            let+ parent =
              lookup_id ~cache_root ~domain_name (Logical_key.parent key)
            in
            Option.map (fun id -> `File (id, Logical_key.leaf key)) parent

  (* The markers are the truth; this restates them the other way round. The mirror
     is written by other processes too ([tsync import], [tsync sync --full]), so no
     care at the mutation sites would make an in-process view sufficient. *)
  let rebuild ~cache_root ~domain_name =
    let base = Cache_layout.manifests_dir ~cache_root domain_name in
    let seen = Hashtbl.create 64 in
    let rec walk dir ~parent_id =
      let* names = F.readdir_list_quiet dir in
      iter_s
        (fun name ->
          if Stored_key.internal_leaf name then return_unit
          else (
            let path = Filename.concat dir name in
            let* is_dir = F.is_directory path in
            if not is_dir then return_unit
            else
              let* marker =
                let+ s = F.read_file_opt (Filename.concat path marker_name) in
                Option.bind s Folder.marker_of_string
              in
              match (marker, parent_id) with
                (* No marker means no id, and filing children under the nearest
                   marked ancestor would name a path they are not at. *)
                | None, _ -> walk path ~parent_id:None
                | Some m, None -> walk path ~parent_id:(Some m.Folder.id)
                | Some m, Some parent ->
                    Hashtbl.replace seen m.Folder.id ();
                    let* () =
                      write_entry ~cache_root ~domain_name ~id:m.Folder.id
                        { parent; name = m.Folder.name }
                    in
                    walk path ~parent_id:(Some m.Folder.id)))
        names
    in
    let* () =
      Io.catch
        (fun () -> walk base ~parent_id:(Some Stored_key.root_id))
        (fun _ -> return_unit)
    in
    (* A stale entry gives no wrong answer, a resolved path being verified against
       the markers, but leaving them grows the directory forever. Neither tree
       exists on a domain nobody has written to, which reads as empty. *)
    let dir = Cache_layout.folders_dir ~cache_root domain_name in
    let* ids = F.readdir_list_quiet dir in
    iter_s
      (fun id ->
        if Hashtbl.mem seen id then return_unit
        else F.unlink_quiet (Filename.concat dir id))
      ids

  (* The index is on-disk data, so a corrupted parent chain can loop and this is
     finite only if it does not. An id seen twice is what says it does. The set
     costs the order [names] already costs, and bounds the climb by the tree's
     own depth. *)
  let climb ~cache_root ~domain_name id =
    let seen = Hashtbl.create 16 in
    let rec go id names =
      if id = Stored_key.root_id then return_some names
      else if Hashtbl.mem seen id then Io.return None
      else (
        Hashtbl.replace seen id ();
        let* entry = read_entry ~cache_root ~domain_name id in
        match entry with
          | None -> Io.return None
          | Some { parent; name } -> go parent (name :: names))
    in
    go id []

  (* The climbed path is checked against the markers before it is believed, so a
     stale entry costs an answer rather than naming some other folder.

     A failure is the answer. Naming a folder goes through {!Layout.ensure_id}
     and so through {!write}, which keeps the index with the mirror whichever
     process is writing; what a lookup meets instead is a folder that is gone,
     and walking the mirror to learn that is not a request's to pay.
     {!Cache_layout.clear} empties the index, and filling it again belongs to
     whoever ran the resync: see {!rebuild}. *)
  let key_of_id ~cache_root ~domain_name ~root id =
    if id = Stored_key.root_id then return_some root
    else
      let* candidate = climb ~cache_root ~domain_name id in
      match candidate with
        | None -> Io.return None
        | Some names ->
            let key = List.fold_left Logical_key.dir_in root names in
            let+ actual = lookup_id ~cache_root ~domain_name key in
            if actual = Some id then Some key else None

  (* A marker travels with its directory and so still spells the old leaf after a
     rename; {!rebuild} reads it, so the new name is written back. *)
  let reparent ~cache_root ~domain_name key =
    if Logical_key.is_root key then return_unit
    else
      let* marker = read ~cache_root ~domain_name key in
      match marker with
        | None -> return_unit
        | Some m ->
            write ~cache_root ~domain_name key
              { m with Folder.name = Logical_key.leaf key }
end
