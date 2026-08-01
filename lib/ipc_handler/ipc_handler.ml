open Lwt.Syntax

module Make (C : Conf.S) (F : File.S) = struct
  module Fs = File_store.Make (C)
  module J = Journal.Make (C)
  module Diag = Diagnostics.Make (C)

  type hooks = {
    path_to_key : string -> string;
    evict : string -> unit Lwt.t;
    restore : string -> unit Lwt.t;
    changed : string -> unit;
    full_resync : unit -> unit Lwt.t;
    status_fields : unit -> (string * Yojson.Safe.t) list;
    stats_fields : unit -> (string * Yojson.Safe.t) list;
    on_stop : unit -> unit;
  }

  (* ── JSON helpers ─────────────────────────────────────────────────────── *)

  let ok_json fields =
    Yojson.Safe.to_string (`Assoc (("ok", `Bool true) :: fields))

  (* The code is what a caller acts on; the prose is for whoever reads a log. *)
  let error_code_json code msg =
    Yojson.Safe.to_string
      (`Assoc
         [
           ("ok", `Bool false);
           ("code", `String (Ipc_error.to_string code));
           ("error", `String msg);
         ])

  let error_json msg = error_code_json `Internal msg
  let fail code msg = Lwt.return (error_code_json code msg)
  let not_found what = fail `Not_found ("not found: " ^ what)

  let get_str obj key =
    match List.assoc_opt key obj with Some (`String s) -> s | _ -> ""

  let get_int obj key =
    match List.assoc_opt key obj with Some (`Int n) -> Some n | _ -> None

  (* ── Naming items ─────────────────────────────────────────────────────────
     A request names what it wants either by reference or, for the callers that
     predate them, by logical key. Everything below works in keys; references
     are turned into one here and nowhere else. *)

  module Ir = Item_ref.Make (C)

  let target obj =
    match List.assoc_opt "ref" obj with
      | Some (`String s) -> Item_ref.parse s
      | _ -> `Key (get_str obj "path")

  (* The item's own reference, its container's, and its leaf name — everything
     needed to describe it to a caller that does not know the key layout.

     A directory costs one marker read for its own id; a file costs one for its
     parent's, which every file in a listing shares, so a listing resolves it
     once rather than per entry. *)
  let ref_str r = `String (Item_ref.to_string r)

  let naming_fields ~container_id key =
    let rel = Key.strip_prefix ~domain_prefix:C.domain_prefix key in
    let body = Key.chop_slash rel in
    let name = if body = "" then C.domain_name else Filename.basename body in
    let parent =
      if container_id = Folder.root_id then `Root else `Dir container_id
    in
    let+ self =
      if body = "" then Lwt.return_some `Root
      else if Key.is_dir rel then
        let+ id =
          Folder_ids.lookup_id ~cache_root:C.cache_root
            ~domain_name:C.domain_name body
        in
        Option.map (fun id -> `Dir id) id
      else Lwt.return_some (`File (container_id, name))
    in
    match self with
      | None -> []
      | Some self ->
          [
            ("ref", ref_str self);
            ("parentRef", ref_str parent);
            ("name", `String name);
            (* Still reported for the callers that speak in paths — the CLI, the
               test harness. Nothing that names items by reference needs it. *)
            ("key", `String key);
          ]

  let lookup_folder rel =
    if rel = "" then Lwt.return_some Folder.root_id
    else
      Folder_ids.lookup_id ~cache_root:C.cache_root ~domain_name:C.domain_name
        rel

  let rel_body key =
    Key.chop_slash (Key.strip_prefix ~domain_prefix:C.domain_prefix key)

  (* The id of the folder [key] itself is — for a directory key. *)
  let own_folder_id key = lookup_folder (rel_body key)

  (* The id of the folder [key] sits in. *)
  let parent_folder_id key = lookup_folder (Key.parent (rel_body key))

  (* ── File operation handlers ──────────────────────────────────────────── *)

  (* Resolve the manifest once (local sidecar, else a single backend GET) and
     derive size, mtime, etag and upload state from it. Going through F.stat
     plus a separate etag lookup would fetch the same manifest up to twice
     more per call, and fileproviderd stats items constantly. *)
  (* A directory's mtime is reported as zero and its etag as its own id. Both
     are constant for as long as the folder exists, which is what a caller
     wanting to know whether it changed needs: the previous answer was the
     current clock, so every look said the directory had just changed. What did
     change inside it arrives through the change feed, not through the parent. *)
  let dir_fields id =
    [
      ("kind", `String "dir");
      ("size", `Int 0);
      ("mtime", `Float 0.);
      ("etag", `String id);
      ("isUploaded", `Bool true);
    ]

  let file_fields ~size ~mtime ~etag ~is_uploaded ~symlink =
    [
      ( "kind",
        `String (match symlink with None -> "file" | Some _ -> "symlink") );
      ("size", `Int size);
      ("mtime", `Float mtime);
      ("etag", `String etag);
      ("isUploaded", `Bool is_uploaded);
    ]
    @ match symlink with None -> [] | Some t -> [("symlinkTarget", `String t)]

  (* What the reference said it was naming. A file reference and a directory
     reference resolve to keys that differ only by a trailing slash, so without
     this a directory would answer to both — and whichever the caller recorded
     would be the one it used to build its children's keys. One item, one
     reference, or the two spellings drift apart. *)
  let expected_kind = function
    | `File _ -> `File
    | `Dir _ | `Root -> `Dir
    | _ -> `Any

  let handle_stat ?(expect = `Any) key =
    let* mst = Fs_util.stat_opt_large (F.manifest_path key) in
    let is_dir =
      match mst with
        | Some { Unix.LargeFile.st_kind = Unix.S_DIR; _ } -> true
        | _ -> false
    in
    if (expect = `File && is_dir) || (expect = `Dir && not is_dir) then
      not_found key
    else
      let* container = parent_folder_id key in
      let container_id = Option.value container ~default:Folder.root_id in
      let* naming = naming_fields ~container_id key in
      if naming = [] then not_found key
      else (
        match mst with
          | Some { Unix.LargeFile.st_kind = Unix.S_DIR; _ } -> (
              let* own = own_folder_id key in
              match own with
                | None -> not_found key
                | Some id -> Lwt.return (ok_json (naming @ dir_fields id)))
          | _ -> (
              (* Unsynced local edits answer from the staged manifest: it is the
               authority for size and mtime until the upload publishes. *)
              let* staged = F.resolve key in
              match staged with
                | Some (`Staged (st, _)) ->
                    Lwt.return
                      (ok_json
                         (naming
                         @ file_fields
                             ~size:(Int64.to_int st.Manifest.s_size)
                             ~mtime:st.Manifest.s_mtime ~etag:""
                             ~is_uploaded:false ~symlink:None))
                | Some (`Published _) | None -> (
                    let* m = F.resolved_manifest key in
                    match m with
                      | Some m ->
                          Lwt.return
                            (ok_json
                               (naming
                               @ file_fields
                                   ~size:(Int64.to_int m.Manifest.size)
                                   ~mtime:m.Manifest.mtime ~etag:m.Manifest.h1
                                   ~is_uploaded:true ~symlink:m.Manifest.symlink
                               ))
                      | None -> not_found key)))

  (* The listed objects are manifests, so their backend size/mtime are the manifest's,
     not the file's. Resolve the manifest (local sidecar, else fetched from the backend)
     to report the real logical size/mtime and the content hash (h1) as the etag — the
     same identity stat returns. Dirty or unknown files have no clean hash: fall back to
     the backend metadata with an empty etag. *)
  (* Bounds concurrent per-file manifest resolutions during enumeration. *)
  let resolve_pool =
    Lwt_pool.create (max 1 C.max_downloads) (fun () -> Lwt.return_unit)

  let file_entry_json ~container_id (e : Backend.file_entry) =
    Lwt_pool.use resolve_pool @@ fun () ->
    let* naming = naming_fields ~container_id e.key in
    let+ m = F.resolved_manifest e.key in
    match m with
      | Some m ->
          `Assoc
            (naming
            @ file_fields
                ~size:(Int64.to_int m.Manifest.size)
                ~mtime:m.Manifest.mtime ~etag:m.Manifest.h1 ~is_uploaded:true
                ~symlink:m.Manifest.symlink)
      | _ ->
          `Assoc
            (naming
            @ file_fields ~size:e.size ~mtime:e.last_modified ~etag:""
                ~is_uploaded:true ~symlink:None)

  (* One list, each entry saying what kind it is. Directories and files differ in
     what describes them, not in how they are named or asked about, and every
     caller merged the two lists back together anyway. *)
  let handle_list_dir prefix =
    let* container = own_folder_id prefix in
    match container with
      | None -> not_found prefix
      | Some container_id ->
          let* files, dirs = F.list_children ~prefix in
          (* map_p: uncached entries each cost a backend GET; resolving them
             sequentially made cold enumeration O(files) round trips end-to-end.
             [resolve_pool] bounds the fan-out; map_p preserves result order. *)
          let* files_json =
            Lwt_list.map_p (file_entry_json ~container_id) files
          in
          let+ dirs_json =
            Lwt_list.map_s
              (fun (d, _mtime) ->
                let key = prefix ^ d ^ "/" in
                let* naming = naming_fields ~container_id key in
                let+ id = own_folder_id key in
                match (naming, id) with
                  | [], _ | _, None -> None
                  | naming, Some id -> Some (`Assoc (naming @ dir_fields id)))
              dirs
          in
          ok_json
            [("items", `List (List.filter_map Fun.id dirs_json @ files_json))]

  (* Every file under [prefix], at any depth. Entries are grouped by the folder
     they are in so each folder's id is resolved once rather than per file. *)
  let handle_list_all prefix =
    let* files = F.list_tree ~prefix in
    let by_parent = Hashtbl.create 16 in
    List.iter
      (fun (e : Backend.file_entry) ->
        let parent = Key.parent (rel_body e.key) in
        Hashtbl.replace by_parent parent
          (e :: Option.value (Hashtbl.find_opt by_parent parent) ~default:[]))
      files;
    let+ groups =
      Lwt_list.map_s
        (fun (parent, entries) ->
          let* id = lookup_folder parent in
          match id with
            | None -> Lwt.return []
            | Some container_id ->
                Lwt_list.map_p
                  (file_entry_json ~container_id)
                  (List.rev entries))
        (Hashtbl.fold (fun k v acc -> (k, v) :: acc) by_parent [])
    in
    ok_json [("items", `List (List.concat groups))]

  (* ── Change feed (journal delta) ──────────────────────────────────────── *)

  (* Journal keys are relative to the domain prefix; the FileProvider uses full
     keys as item identifiers, with directories ending in "/". *)
  let full_key ?(dir = false) rel =
    let k = C.domain_prefix ^ rel in
    if dir then Key.ensure_slash k else k

  let dir_id_field = function None -> [] | Some id -> [("id", `String id)]

  (* An op has to name the item it touched the same way everything else does, or
     a reader that knows items by reference cannot act on it — and a deletion is
     precisely the case where it cannot go and look the name up afterwards.

     A file's reference needs its parent's id; a directory's own id travels in
     the op ({!Journal.op}). [None] when the parent is not in this client's
     mirror yet, which happens only in the window between a foreign entry being
     published and this client's poller applying it. *)
  let file_ref ~lookup rel =
    let+ pid = lookup (Key.parent rel) in
    Option.map (fun pid -> `File (pid, Filename.basename rel)) pid

  let dir_ref ~lookup rel = function
    | Some id -> Lwt.return_some (`Dir id)
    | None ->
        (* An entry written before ids were carried. *)
        let+ id = lookup rel in
        Option.map (fun id -> `Dir id) id

  let parent_ref ~lookup rel =
    let+ pid = lookup (Key.parent rel) in
    Option.map (fun pid -> if pid = Folder.root_id then `Root else `Dir pid) pid

  let named self parent rel =
    match (self, parent) with
      | Some self, Some parent ->
          Some
            [
              ("ref", ref_str self);
              ("parentRef", ref_str parent);
              ("name", `String (Filename.basename rel));
            ]
      | _ -> None

  let op_to_json ~lookup op =
    let file_ref = file_ref ~lookup and dir_ref = dir_ref ~lookup in
    let parent_ref = parent_ref ~lookup in
    let with_naming fields = function
      | None -> None
      | Some naming -> Some (`Assoc (fields @ naming))
    in
    match op with
      | `Put (key, size) ->
          let* self = file_ref key in
          let+ parent = parent_ref key in
          with_naming
            [
              ("op", `String "put");
              ("key", `String (full_key key));
              ("size", `Int (Int64.to_int size));
            ]
            (named self parent key)
      | `Delete key ->
          let* self = file_ref key in
          let+ parent = parent_ref key in
          with_naming
            [("op", `String "delete"); ("key", `String (full_key key))]
            (named self parent key)
      | `Mkdir (key, id) ->
          let* self = dir_ref key id in
          let+ parent = parent_ref key in
          with_naming
            ([
               ("op", `String "mkdir"); ("key", `String (full_key ~dir:true key));
             ]
            @ dir_id_field id)
            (named self parent key)
      | `Rmdir (key, id) ->
          let* self = dir_ref key id in
          let+ parent = parent_ref key in
          with_naming
            ([
               ("op", `String "rmdir"); ("key", `String (full_key ~dir:true key));
             ]
            @ dir_id_field id)
            (named self parent key)
      | `Rename { Journal.dst; src; is_dir; id; _ } -> (
          (* A directory keeps its id across the move, which is what says the two
             paths are one folder rather than a disappearance and an unrelated
             arrival. A file's reference changes, so both ends are named. *)
          let* self = if is_dir then dir_ref dst id else file_ref dst in
          let* parent = parent_ref dst in
          let+ src_self = if is_dir then Lwt.return self else file_ref src in
          let fields =
            [
              ("op", `String "rename");
              ("key", `String (full_key ~dir:is_dir dst));
              ("src", `String (full_key ~dir:is_dir src));
              ("is_dir", `Bool is_dir);
            ]
            @ dir_id_field id
          in
          match (named self parent dst, src_self) with
            | Some naming, Some src_self ->
                Some (`Assoc (fields @ naming @ [("srcRef", ref_str src_self)]))
            | _ -> None)

  let newest_key ~init keys =
    List.fold_left (fun acc (k, _) -> if k > acc then k else acc) init keys

  (* The journal can no longer bridge [anchor]→now, so the caller must re-list
     everything. This happens when the journal has been pruned past the anchor
     (oldest surviving entry is newer), was cleaned up entirely while changes are
     still pending (anchor ≠ cursor but no entries left), or the anchor is
     unparseable. [keys] is ascending, so head = oldest. *)
  let cannot_bridge anchor keys =
    match keys with
      | [] -> true
      | (oldest, _) :: _ -> (
          try
            Journal.timestamp_ms_of_filename oldest
            > Journal.timestamp_ms_of_filename anchor
          with _ -> true)

  let handle_changes_since anchor =
    let* keys = Fs.list_journal_keys () in
    let* fetched = Fs.fetch_cursor () in
    let cursor =
      match fetched with
        | Some c -> newest_key ~init:c keys
        | None -> newest_key ~init:"" keys
    in
    (* Up to date — safe to report even if the journal is empty or was pruned. *)
    if anchor <> "" && anchor = cursor then
      Lwt.return
        (ok_json
           [
             ("stale", `Bool false);
             ("cursor", `String cursor);
             ("ops", `List []);
           ])
    else if anchor <> "" && cannot_bridge anchor keys then
      Lwt.return (ok_json [("stale", `Bool true)])
    else (
      let my_uuid = J.client_uuid () in
      let foreign =
        keys
        |> List.filter (fun (k, _) -> anchor = "" || k > anchor)
        |> List.filter (fun (_, uuid) -> uuid <> my_uuid)
      in
      let* ops_lists =
        Lwt_list.map_s (fun (ek, _) -> Fs.get_journal_entry ek) foreign
      in
      let ops =
        List.concat_map (function Some o -> o | None -> []) ops_lists
      in
      (* A batch answers for itself: a folder created earlier in it is not in
         this client's mirror yet, but the op that created it carries its id, so
         a file put into it can still be named. Without this, every foreign
         "make a folder, then write into it" would report a gap. *)
      let learned : (string, string) Hashtbl.t = Hashtbl.create 8 in
      let lookup rel =
        match Hashtbl.find_opt learned rel with
          | Some id -> Lwt.return_some id
          | None -> lookup_folder rel
      in
      (* Directory ops spell their key with a trailing slash; a lookup is by the
         path without one. *)
      let note = function
        | `Mkdir (rel, Some id) ->
            Hashtbl.replace learned (Key.chop_slash rel) id
        | `Rename { Journal.dst; is_dir = true; id = Some id; _ } ->
            Hashtbl.replace learned (Key.chop_slash dst) id
        | _ -> ()
      in
      let+ described =
        Lwt_list.map_s
          (fun op ->
            note op;
            op_to_json ~lookup op)
          ops
      in
      (* An op naming something this client cannot describe yet — a folder whose
         creation the poller has not applied — is reported as a gap rather than
         guessed at or quietly dropped. The caller re-lists, which is correct and
         costs a scan; the window is the couple of seconds between an entry being
         published and this client ingesting it.
         ponytail: a whole re-list for a rare race. Carry the parent id on file
         ops too, as directory ops already do, if it ever shows up in practice. *)
      if List.exists Option.is_none described then
        ok_json [("stale", `Bool true)]
      else
        ok_json
          [
            ("stale", `Bool false);
            ("cursor", `String cursor);
            ("ops", `List (List.filter_map Fun.id described));
          ])

  (* The backend cursor key is bumped on a lag, so fold it with the newest journal
     entry — the same value handle_changes_since reports — so the anchor the caller
     starts from is never behind what changes_since would hand back. *)
  let handle_current_cursor () =
    let* keys = Fs.list_journal_keys () in
    let+ fetched = Fs.fetch_cursor () in
    ok_json
      [
        ( "cursor",
          `String (newest_key ~init:(Option.value ~default:"" fetched) keys) );
      ]

  (* The caller wants a real file at a place of its choosing, and takes it over
     from there — the daemon keeps the content in the chunk store, not as a
     file. Writing straight to "dest" spares the caller a move it may not be
     permitted to make. *)
  let handle_ensure_cached ~dst_path key =
    let+ () = F.assemble_to key ~dst_path in
    ok_json [("localPath", `String dst_path)]

  (* The answer carries the range actually served rather than echoing the one
     asked for: it is short at end of file, and the caller has to know how much
     of the file it now holds. *)
  let handle_fetch_range ~dst_path ~offset ~length key =
    let+ n = F.fetch_range key ~dst_path ~offset ~length in
    ok_json
      [
        ("localPath", `String dst_path);
        ("offset", `Int offset);
        ("length", `Int n);
      ]

  let handle_create key =
    let+ () = F.create key in
    ok_json []

  (* The extension hands back a complete file. It is taken over where it is — no
     copy of the bytes and no chunking pass before the upload — and answered from
     the staged metadata, which is the size and mtime that will be published. *)
  let handle_write key staging_path =
    ignore (F.cancel_upload key);
    let* () = F.write_whole key ~src_path:staging_path in
    let* () = F.queue_put key in
    let+ resolved = F.resolve key in
    match resolved with
      | Some (`Staged (st, _)) ->
          ok_json
            [
              ("size", `Int (Int64.to_int st.Manifest.s_size));
              ("mtime", `Float st.Manifest.s_mtime);
            ]
      | Some (`Published m) ->
          (* The upload already finished and promoted. *)
          ok_json
            [
              ("size", `Int (Int64.to_int m.Manifest.size));
              ("mtime", `Float m.Manifest.mtime);
            ]
      | None -> ok_json []

  let handle_delete key =
    let+ () = F.delete key in
    ok_json []

  let handle_rename src_key dst_key =
    let+ () =
      F.rename ~src:(Key.chop_slash src_key) ~dst:(Key.chop_slash dst_key)
    in
    ok_json []

  let handle_mkdir key =
    let+ () = F.mkdir key in
    ok_json []

  let handle_symlink key target =
    let+ () = F.symlink ~target key in
    ok_json []

  let handle_rmdir key =
    let+ () = F.rmdir key in
    ok_json []

  let handle_revert hooks key version =
    let version = if version = "" then None else Some version in
    let+ () = F.revert ?version key in
    hooks.changed key;
    ok_json []

  module Sh = Share.Make (C)

  (* [key] is an item's full storage key ([C.domain_prefix ^ rel], directories
     end in "/"); recover the domain-relative path the share core expects. *)
  let handle_share key =
    let rel =
      Key.chop_slash (Key.strip_prefix ~domain_prefix:C.domain_prefix key)
    in
    let expires = int_of_float (Unix.time ()) + (7 * 86400) in
    let+ result = Sh.create ~expires ~rel () in
    match result with
      | Ok url -> ok_json [("url", `String url)]
      | Error msg -> error_json msg

  (* ── Dispatch ───────────────────────────────────────────────────────────
     The action strings are a wire contract with the FileProvider extension
     (see macos/TsyncFileProvider/IPC.swift): rename the handlers freely, never
     these. *)

  (* Actions that change the domain. A read-only domain refuses them here rather
     than leaving it to a frontend's own idea of what it should offer: the
     capabilities a UI honours are advice, and a direct request is not obliged to
     have taken it. Sharing is deliberately absent — a share manifest lives
     outside every domain root, so publishing one changes no domain content. *)
  let mutating =
    [
      "create";
      "write";
      "delete";
      "rename";
      "mkdir";
      "rmdir";
      "symlink";
      "revert";
    ]

  let handler hooks line =
    match Yojson.Safe.from_string line with
      | exception _ ->
          Lwt.return (error_code_json `Invalid "invalid JSON", `Continue)
      | `Assoc obj ->
          let action = get_str obj "action" in
          let path = get_str obj "path" in
          (* What the request names, as a key. [None] means the reference points
             at something that is no longer there — which is the answer, not a
             failure to work it out. *)
          let with_target_ref f =
            let t = target obj in
            let* key = Ir.resolve t in
            match key with
              | None -> not_found (Item_ref.to_string t)
              | Some key -> f t key
          in
          let with_target f = with_target_ref (fun _ key -> f key) in
          (* A location to put something: a container and a leaf name. Callers
             that still speak in keys give the whole key as "path". *)
          let with_destination f =
            match List.assoc_opt "parentRef" obj with
              | Some (`String s) -> (
                  let name = get_str obj "name" in
                  if name = "" then fail `Invalid "\"name\" is required"
                  else
                    let* parent = Ir.resolve (Item_ref.parse s) in
                    match parent with
                      | None -> not_found s
                      | Some parent -> f (parent ^ name))
              | _ -> f path
          in
          let* resp =
            Lwt.catch
              (fun () ->
                if C.read_only && List.mem action mutating then
                  fail `Read_only
                    (Printf.sprintf "'%s' is read-only" C.domain_name)
                else (
                  match action with
                    | "stat" ->
                        with_target_ref (fun t key ->
                            handle_stat ~expect:(expected_kind t) key)
                    | "list_dir" -> with_target handle_list_dir
                    | "list_all" -> with_target handle_list_all
                    | "changes_since" ->
                        handle_changes_since (get_str obj "arg")
                    | "cursor" -> handle_current_cursor ()
                    | "ensure_cached" -> (
                        match get_str obj "dest" with
                          | "" ->
                              fail `Invalid "ensure_cached requires \"dest\""
                          | dst_path ->
                              with_target (handle_ensure_cached ~dst_path))
                    | "fetch_range" -> (
                        match
                          ( get_str obj "dest",
                            get_int obj "offset",
                            get_int obj "length" )
                        with
                          | "", _, _ ->
                              fail `Invalid "fetch_range requires \"dest\""
                          | _, None, _ | _, _, None ->
                              fail `Invalid
                                "fetch_range requires \"offset\" and \"length\""
                          | _, Some offset, Some length
                            when offset < 0 || length <= 0 ->
                              fail `Invalid
                                "fetch_range needs a non-negative \"offset\" \
                                 and a positive \"length\""
                          | dst_path, Some offset, Some length ->
                              with_target
                                (handle_fetch_range ~dst_path ~offset ~length))
                    | "create" -> with_destination handle_create
                    | "write" ->
                        with_destination (fun key ->
                            handle_write key (get_str obj "staging"))
                    | "delete" -> with_target handle_delete
                    | "rename" -> (
                        (* The item moving is named the same way as anywhere
                           else; where it lands is a destination. *)
                        let src_ref =
                          match List.assoc_opt "ref" obj with
                            | Some (`String s) -> Item_ref.parse s
                            | _ -> `Key (get_str obj "src")
                        in
                        let* src = Ir.resolve src_ref in
                        match src with
                          | None -> not_found (Item_ref.to_string src_ref)
                          | Some src ->
                              with_destination (fun dst ->
                                  handle_rename src dst))
                    | "mkdir" ->
                        with_destination (fun key ->
                            handle_mkdir (Key.ensure_slash key))
                    | "symlink" ->
                        with_destination (fun key ->
                            handle_symlink key (get_str obj "target"))
                    | "rmdir" -> with_target handle_rmdir
                    | "share" -> with_target handle_share
                    (* These carry a filesystem path the user typed, not a
                       reference: they come from the CLI, which knows where it
                       is standing and nothing about ids. *)
                    | "evict" ->
                        let+ () = hooks.evict (hooks.path_to_key path) in
                        ok_json []
                    | "restore" ->
                        let+ () = hooks.restore (hooks.path_to_key path) in
                        ok_json []
                    | "revert" ->
                        handle_revert hooks (hooks.path_to_key path)
                          (get_str obj "arg")
                    | "full_resync" ->
                        let+ () = hooks.full_resync () in
                        ok_json []
                    | "status" ->
                        Lwt.return
                          (ok_json
                             (("domain", `String C.domain_name)
                             :: ("running", `Bool true)
                             :: hooks.status_fields ()))
                    | "stats" ->
                        (* The whole picture, assembled by {!Diagnostics} so a mount
                         and an http-proxy server answer in one shape. This daemon
                         is one frontend of one domain, so it reports itself twice
                         over: once at the top as the process answering, and once
                         in the domain's [frontends] with the queues only it knows
                         — which is where a proxy asking us over IPC picks it up.
                         [totals] reaches for the store, so it is asked for
                         explicitly, as a comma-separated set: [exact] counts
                         every chunk rather than estimating from a sample of
                         shards, and [reload] recomputes rather than serving what
                         was counted before. *)
                        let flags =
                          String.split_on_char ',' (get_str obj "arg")
                        in
                        let has f = List.mem f flags in
                        let exact = has "exact" in
                        let reload = has "reload" in
                        let totals = has "totals" in
                        let* staged = F.staged_count () in
                        let queues =
                          [
                            ("reachable", `Bool true);
                            ("pendingDownloads", `Int (F.downloads_in_flight ()));
                            ("stagedFiles", `Int staged);
                            ( "downloadsCompleted",
                              `Int (F.downloads_completed_count ()) );
                            ("maxUploads", `Int C.max_uploads);
                            ("maxDownloads", `Int C.max_downloads);
                            (* A mount gone quiet while its backends answer fine is
                             usually this: the metadata lock held, with callers
                             queued behind it. *)
                            ("metaLocked", `Bool (F.meta_locked ()));
                            ("metaWaiting", `Bool (F.meta_waiters ()));
                          ]
                          @ hooks.stats_fields ()
                        in
                        let frontend_type =
                          match List.assoc_opt "frontend" queues with
                            | Some (`String t) -> t
                            | _ -> "unknown"
                        in
                        (* A frontend entry names itself with [type], the same key a
                         backend entry uses. The frontends supply it as [frontend]
                         in their stats fields, so normalise here — once, where the
                         entry is built — rather than leaving every reader to know
                         both spellings. *)
                        let queues =
                          ("type", `String frontend_type)
                          :: List.remove_assoc "frontend" queues
                        in
                        let+ domain =
                          Diag.domain_json ~totals ~exact ~reload
                            ~frontends:[`Assoc queues]
                            ()
                        in
                        ok_json
                          (Diagnostics.self_json
                             ~extra:
                               [
                                 ("frontend", `String frontend_type);
                                 ("serves", `List [`String C.domain_name]);
                               ]
                             ()
                          @ [("domains", `List [domain])])
                    | "download_progress" ->
                        with_target (fun key ->
                            Lwt.return
                              (match F.download_progress key with
                                | None -> ok_json [("active", `Bool false)]
                                | Some (done_, total) ->
                                    ok_json
                                      [
                                        ("active", `Bool true);
                                        ("bytesDownloaded", `Int done_);
                                        ("totalBytes", `Int total);
                                      ]))
                    | "stop" ->
                        hooks.on_stop ();
                        Lwt.return (ok_json [])
                    (* Answered here so the connection can be handed over; the
                     event stream itself belongs to {!Ipc.serve}. *)
                    | "subscribe" when get_str obj "domain" = "" ->
                        fail `Invalid "subscribe requires \"domain\""
                    | "subscribe" -> Lwt.return (ok_json [])
                    | _ -> fail `Invalid ("unknown action: " ^ action)))
              (fun exn ->
                Lwt.return
                  (error_code_json (Ipc_error.of_exn exn)
                     (Printexc.to_string exn)))
          in
          let ctl =
            match action with
              | "stop" -> `Stop
              (* The domain this request was routed to, not the name it asked
                 for: they are the same by construction, and this one is the
                 topic events are actually published under. *)
              | "subscribe" when get_str obj "domain" <> "" ->
                  `Subscribe C.domain_name
              | _ -> `Continue
          in
          Lwt.return (resp, ctl)
      | _ -> Lwt.return (error_json "expected JSON object", `Continue)
end
