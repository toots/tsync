open Lwt.Syntax

(* The one place that knows the shape of a failure on this wire: a code the
   caller acts on, and prose for whoever reads the log. *)
let error_reply code msg =
  Yojson.Safe.to_string
    (`Assoc
       [
         ("ok", `Bool false);
         ("code", `String (Ipc_error.to_string code));
         ("error", `String msg);
       ])

module type S = sig
  type hooks = {
    path_to_key : string -> Logical_key.t option;
    evict : Logical_key.t -> unit Lwt.t;
    restore : Logical_key.t -> unit Lwt.t;
    changed : Logical_key.t -> unit;
    full_resync : unit -> unit Lwt.t;
    status_fields : unit -> (string * Yojson.Safe.t) list;
    stats_fields : unit -> (string * Yojson.Safe.t) list;
    on_stop : unit -> unit;
  }

  (** How a subscriber names [key], for a frontend telling one to act on an
      item. [None] for a key whose folder this client cannot resolve. *)
  val item_ref : Logical_key.t -> string option Lwt.t

  val handler :
    hooks ->
    string ->
    (string * [ `Continue | `Stop | `Subscribe of string ]) Lwt.t
end

module Make (C : Conf.S) (F : File_ops.S) : S = struct
  module Fs = File_store.Make (C)
  module J = Journal.Make (C)
  module Diag = Diagnostics.Make (C)

  type hooks = {
    path_to_key : string -> Logical_key.t option;
    evict : Logical_key.t -> unit Lwt.t;
    restore : Logical_key.t -> unit Lwt.t;
    changed : Logical_key.t -> unit;
    full_resync : unit -> unit Lwt.t;
    status_fields : unit -> (string * Yojson.Safe.t) list;
    stats_fields : unit -> (string * Yojson.Safe.t) list;
    on_stop : unit -> unit;
  }

  (* Facts, not a filtered view: which of these is worth a menu row is a
     question for whatever draws the menu, and `tsync status' wants all of them. *)
  let downloading_json () =
    List.map
      (fun (d : File_ops.downloading) ->
        `Assoc
          [
            ("name", `String d.File_ops.d_name);
            ("rel", `String d.d_rel);
            ("bytes", `Int d.d_bytes);
            ("size", `Int d.d_size);
            ("seconds", `Float d.d_seconds);
            ("rate", `Float d.d_rate);
          ])
      (F.downloading_now ())

  let ok_json fields =
    Yojson.Safe.to_string (`Assoc (("ok", `Bool true) :: fields))

  let error_code_json = error_reply
  let error_json msg = error_code_json `Internal msg
  let fail code msg = Lwt.return (error_code_json code msg)
  let not_found what = fail `Not_found ("not found: " ^ what)

  let get_str obj key =
    match List.assoc_opt key obj with Some (`String s) -> s | _ -> ""

  let get_int obj key =
    match List.assoc_opt key obj with Some (`Int n) -> Some n | _ -> None

  (* A request names its target by reference or, for the callers that predate
     them, by logical key. Everything below works in keys: references are
     resolved here and nowhere else. *)

  module Ir = Item_ref.Make (C)
  module Lk = Logical_key.Make (C)

  let key_of_id id =
    Folder_ids.key_of_id ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~root:Lk.root id

  (* [None] when nothing is there any more, which is the point of naming a
     directory by id: a caller is told it is gone rather than handed a path
     resolving to whatever now sits there. Resolves only what this client
     already records and mints nothing. *)
  let resolve : Item_ref.t -> Logical_key.t option Lwt.t = function
    | `Root -> Lwt.return_some Lk.root
    | `Dir id -> key_of_id id
    | `File (id, name) ->
        let+ dir = key_of_id id in
        Option.map (fun dir -> Logical_key.file_in dir name) dir
    | `Logical_key k -> Lwt.return_some k
    | `Bad _ -> Lwt.return_none

  let target obj =
    match List.assoc_opt "ref" obj with
      | Some (`String s) -> Ir.parse s
      | _ -> Ir.parse (get_str obj "path")

  (* Reference, container reference and leaf name: enough to describe an item to
     a caller that does not know the key layout.

     A directory costs one marker read for its own id, a file one for its
     parent's — shared across a listing, so it resolves once, not per entry. *)
  let ref_str r = `String (Item_ref.to_string r)

  (* The reference an item answers to. [container_id] is passed in because a
     listing resolves the folder once and reuses it for every file under it. *)
  let self_ref ~container_id key =
    let body = Logical_key.path key in
    if body = "" then Lwt.return_some `Root
    else if Logical_key.kind key = `Dir then
      let+ id =
        Folder_ids.lookup_id ~cache_root:C.cache_root ~domain_name:C.domain_name
          key
      in
      Option.map (fun id -> `Dir id) id
    else Lwt.return_some (`File (container_id, Logical_key.leaf key))

  let naming_fields ~container_id key =
    let body = Logical_key.path key in
    let name = if body = "" then C.domain_name else Logical_key.leaf key in
    let parent =
      if container_id = Stored_key.root_id then `Root else `Dir container_id
    in
    let+ self = self_ref ~container_id key in
    match self with
      | None -> []
      | Some self ->
          [
            ("ref", ref_str self);
            ("parentRef", ref_str parent);
            ("name", `String name);
          ]

  let lookup_folder key =
    if Logical_key.is_root key then Lwt.return_some Stored_key.root_id
    else
      Folder_ids.lookup_id ~cache_root:C.cache_root ~domain_name:C.domain_name
        key

  let rel_body = Logical_key.path

  (* For a directory key: the id of the folder [key] is. *)
  let own_folder_id key = lookup_folder key

  (* The id of the folder [key] sits in. *)
  let parent_folder_id key = lookup_folder (Logical_key.parent key)

  (* How a subscriber names an item, for a frontend pushing it news about one.
     Resolves the folder itself, having no listing to share one with. *)
  let item_ref key =
    let* container = parent_folder_id key in
    let container_id = Option.value container ~default:Stored_key.root_id in
    let+ self = self_ref ~container_id key in
    Option.map Item_ref.to_string self

  (* One manifest resolution (sidecar, else a single GET) yields size, mtime,
     etag and upload state; F.stat plus a separate etag lookup would fetch the
     same manifest twice more per call, and fileproviderd stats constantly.

     A directory reports mtime zero and its own id as etag, both constant for the
     folder's lifetime, so a caller checking for change is not told the directory
     just changed on every look. *)
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

  (* A reference says which kind it names, and {!handle_stat} checks that against
     the tree: a [f:] reference must not answer for a folder. A bare key says
     nothing, so it is held to neither. *)
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
      not_found (Logical_key.to_string key)
    else
      let* container = parent_folder_id key in
      let container_id = Option.value container ~default:Stored_key.root_id in
      let* naming = naming_fields ~container_id key in
      if naming = [] then not_found (Logical_key.to_string key)
      else (
        match mst with
          | Some { Unix.LargeFile.st_kind = Unix.S_DIR; _ } -> (
              let* own = own_folder_id key in
              match own with
                | None -> not_found (Logical_key.to_string key)
                | Some id -> Lwt.return (ok_json (naming @ dir_fields id)))
          | _ -> (
              (* The staged manifest is authoritative for size and mtime until
               the upload publishes. *)
              let* staged = F.resolve key in
              match staged with
                | Some (`Staged (st, _)) ->
                    Lwt.return
                      (ok_json
                         (naming
                         @ file_fields
                             ~size:(Int64.to_int st.Staged_manifest.s_size)
                             ~mtime:st.Staged_manifest.s_mtime ~etag:""
                             ~is_uploaded:false ~symlink:None))
                | Some (`Published _) | None -> (
                    let* m = F.published key in
                    match m with
                      | Some m ->
                          Lwt.return
                            (ok_json
                               (naming
                               @ file_fields
                                   ~size:(Int64.to_int (Manifest.size m))
                                   ~mtime:(Manifest.mtime m)
                                   ~etag:(Manifest.h1 m) ~is_uploaded:true
                                   ~symlink:(Manifest.symlink m)))
                      | None -> not_found (Logical_key.to_string key))))

  (* Bounds concurrent per-file manifest resolutions during enumeration. *)
  let resolve_pool = Lwt_bounded.create ~max:C.max_downloads ()

  (* Listed objects are manifests, so their backend size/mtime describe the
     manifest, not the file. Resolving gives the logical size/mtime and h1 as the
     etag — the identity stat returns. A dirty file has no clean hash: fall back
     to the backend metadata with an empty etag. *)
  let file_entry_json ~container_id (e : Checkout.listed) =
    let key = e.key in
    (* The slot is taken for the resolution, not for deciding there is none to
       do: the list is as long as the folder, and only the GETs need
       bounding. *)
    Lwt_bounded.use resolve_pool @@ fun () ->
    let* naming = naming_fields ~container_id key in
    let+ m = F.published key in
    match m with
      | Some m ->
          Some
            (`Assoc
               (naming
               @ file_fields
                   ~size:(Int64.to_int (Manifest.size m))
                   ~mtime:(Manifest.mtime m) ~etag:(Manifest.h1 m)
                   ~is_uploaded:true ~symlink:(Manifest.symlink m)))
      | _ ->
          Some
            (`Assoc
               (naming
               @ file_fields ~size:e.size ~mtime:e.mtime ~etag:""
                   ~is_uploaded:true ~symlink:None))

  (* An item under a folder this client holds no id for cannot be named to a
     caller, and both listings answer with what they could name. How many they
     could not is part of the answer: a short list and a complete one are
     otherwise the same reply, which is how a folder stays invisible with
     nothing looking wrong. *)
  let unnamed_field prefix n =
    if n = 0 then []
    else begin
      Log.warn
        "%s: %d item%s this client has no folder id for; run 'tsync sync \
         --full'"
        prefix n
        (if n = 1 then "" else "s");
      [("unnamed", `Int n)]
    end

  (* One list, each entry tagged by kind: files and directories differ in what
     describes them, not in how they are named.

     The prefix is read as a folder whatever the caller spelled it as, a
     path-speaking client having no way to mark one. *)
  let handle_list_dir prefix =
    let prefix = Lk.dir (Logical_key.path prefix) in
    let* container = own_folder_id prefix in
    match container with
      | None -> not_found (Logical_key.to_string prefix)
      | Some container_id ->
          let* files, dirs = F.list_children ~prefix in
          (* Uncached entries each cost a GET, so sequential resolution makes a
             cold enumeration O(files) round trips. [resolve_pool] bounds the
             fan-out; map_p preserves order. *)
          let* files_json =
            Lwt_list.filter_map_p (file_entry_json ~container_id) files
          in
          let+ dirs_json =
            Lwt_list.map_s
              (fun (d, _mtime) ->
                let key = Logical_key.dir_in prefix d in
                let* naming = naming_fields ~container_id key in
                let+ id = own_folder_id key in
                match (naming, id) with
                  | [], _ | _, None -> None
                  | naming, Some id -> Some (`Assoc (naming @ dir_fields id)))
              dirs
          in
          let named = List.filter_map Fun.id dirs_json in
          let unnamed = List.length dirs_json - List.length named in
          ok_json
            (("items", `List (named @ files_json))
            :: unnamed_field (Logical_key.to_string prefix) unnamed)

  (* Grouped by containing folder, so each folder id resolves once, not per
     file. *)
  let handle_list_all prefix =
    let prefix = Lk.dir (Logical_key.path prefix) in
    let* files = F.list_tree ~prefix in
    let by_parent = Hashtbl.create 16 in
    List.iter
      (fun (entry : Checkout.listed) ->
        let parent = Logical_key.parent entry.key in
        Hashtbl.replace by_parent parent
          (entry :: Option.value (Hashtbl.find_opt by_parent parent) ~default:[]))
      files;
    let+ groups =
      Lwt_list.map_s
        (fun (parent, entries) ->
          let* id = lookup_folder parent in
          match id with
            (* The whole group, not one entry: an unnamed folder takes every
               file under it out of the answer. *)
            | None -> Lwt.return (`Unnamed (List.length entries))
            | Some container_id ->
                let+ json =
                  Lwt_list.filter_map_p
                    (file_entry_json ~container_id)
                    (List.rev entries)
                in
                `Named json)
        (Hashtbl.fold (fun k v acc -> (k, v) :: acc) by_parent [])
    in
    let named = List.concat_map (function `Named j -> j | _ -> []) groups in
    let unnamed =
      List.fold_left
        (fun n g -> match g with `Unnamed k -> n + k | `Named _ -> n)
        0 groups
    in
    ok_json
      (("items", `List named)
      :: unnamed_field (Logical_key.to_string prefix) unnamed)

  let dir_id_field = function None -> [] | Some id -> [("id", `String id)]

  (* An op must name its item the way everything else does, since a reader
     knowing items by reference cannot look up a deleted one afterwards.

     A file's reference needs its parent's id; a directory's own id travels in
     the op ({!Journal.op}). [None] while the parent is not yet in this client's
     mirror — the window between a foreign entry being published and the poller
     applying it. *)
  let file_ref ~lookup key =
    let+ pid = lookup (Logical_key.parent key) in
    Option.map (fun pid -> `File (pid, Logical_key.leaf key)) pid

  let dir_ref ~lookup key = function
    | Some id -> Lwt.return_some (`Dir id)
    | None ->
        (* An entry from before ids were carried. *)
        let+ id = lookup key in
        Option.map (fun id -> `Dir id) id

  let parent_ref ~lookup key =
    let+ pid = lookup (Logical_key.parent key) in
    Option.map
      (fun pid -> if pid = Stored_key.root_id then `Root else `Dir pid)
      pid

  let named self parent key =
    match (self, parent) with
      | Some self, Some parent ->
          Some
            [
              ("ref", ref_str self);
              ("parentRef", ref_str parent);
              ("name", `String (Logical_key.leaf key));
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
      | `Put (rel, size) ->
          let key = Lk.file rel in
          let* self = file_ref key in
          let+ parent = parent_ref key in
          with_naming
            [("op", `String "put"); ("size", `Int (Int64.to_int size))]
            (named self parent key)
      | `Delete rel ->
          let key = Lk.file rel in
          let* self = file_ref key in
          let+ parent = parent_ref key in
          with_naming [("op", `String "delete")] (named self parent key)
      | `Mkdir (rel, id) ->
          let key = Lk.dir rel in
          let* self = dir_ref key id in
          let+ parent = parent_ref key in
          with_naming
            ([("op", `String "mkdir")] @ dir_id_field id)
            (named self parent key)
      | `Rmdir (rel, id) ->
          let key = Lk.dir rel in
          let* self = dir_ref key id in
          let+ parent = parent_ref key in
          with_naming
            ([("op", `String "rmdir")] @ dir_id_field id)
            (named self parent key)
      | `Rename { Journal.dst; src; is_dir; id; _ } -> (
          (* A directory keeps its id across a move, which is what marks the two
             paths as one folder. A file's reference changes, so name both
             ends. *)
          let as_key rel = if is_dir then Lk.dir rel else Lk.file rel in
          let dst = as_key dst and src = as_key src in
          let* self = if is_dir then dir_ref dst id else file_ref dst in
          let* parent = parent_ref dst in
          let+ src_self = if is_dir then Lwt.return self else file_ref src in
          let fields =
            [("op", `String "rename"); ("is_dir", `Bool is_dir)]
            @ dir_id_field id
          in
          match (named self parent dst, src_self) with
            | Some naming, Some src_self ->
                Some (`Assoc (fields @ naming @ [("srcRef", ref_str src_self)]))
            | _ -> None)

  let newest_key ~init keys =
    List.fold_left
      (fun acc k ->
        match acc with
          | Some a when Journal.Entry_key.compare k a <= 0 -> acc
          | _ -> Some k)
      init keys

  (* The wire carries the anchor as a string, [""] from a caller that has never
     synced. *)
  let cursor_field = function
    | Some c -> `String (Journal.Entry_key.to_string c)
    | None -> `String ""

  let handle_changes_since anchor =
    let anchor =
      if anchor = "" then None else Journal.Entry_key.of_string anchor
    in
    let* keys = Fs.list_journal_keys () in
    let* fetched = Fs.fetch_cursor () in
    let cursor = newest_key ~init:fetched keys in
    let up_to_date =
      match (anchor, cursor) with
        | Some a, Some c -> Journal.Entry_key.compare a c = 0
        | _ -> false
    in
    (* Up to date: safe even for an empty or pruned journal. *)
    if up_to_date then
      Lwt.return
        (ok_json
           [
             ("stale", `Bool false);
             ("cursor", cursor_field cursor);
             ("ops", `List []);
           ])
    else if
      match anchor with
        | Some a -> Journal.Entry_key.cannot_bridge a keys
        | None -> false
    then Lwt.return (ok_json [("stale", `Bool true)])
    else (
      let my_uuid = J.client_uuid () in
      let foreign =
        keys
        |> List.filter (fun k ->
            match anchor with
              | None -> true
              | Some a -> Journal.Entry_key.compare k a > 0)
        |> List.filter (fun k -> Journal.Entry_key.client_uuid k <> my_uuid)
      in
      let* ops_lists = Lwt_list.map_s Fs.get_journal_entry foreign in
      let ops =
        List.concat_map (function Some o -> o | None -> []) ops_lists
      in
      (* A batch answers for itself: a folder created earlier in it is not in
         the mirror yet, but its creating op carries the id, so a file put into
         it can still be named. Otherwise every foreign "mkdir then write"
         reports a gap. *)
      let learned : (string, string) Hashtbl.t = Hashtbl.create 8 in
      let lookup key =
        match Hashtbl.find_opt learned (Logical_key.path key) with
          | Some id -> Lwt.return_some id
          | None -> lookup_folder key
      in
      let note = function
        | `Mkdir (rel, Some id) -> Hashtbl.replace learned rel id
        | `Rename { Journal.dst; is_dir = true; id = Some id; _ } ->
            Hashtbl.replace learned dst id
        | _ -> ()
      in
      let+ described =
        Lwt_list.map_s
          (fun op ->
            note op;
            op_to_json ~lookup op)
          ops
      in
      (* An op naming a folder the poller has not applied yet is reported as a
         gap rather than guessed at: the caller re-lists. The window is the
         seconds between an entry being published and ingested.
         ponytail: a whole re-list for a rare race. Carry the parent id on file
         ops too, as directory ops already do, if it ever shows up in practice. *)
      if List.exists Option.is_none described then
        ok_json [("stale", `Bool true)]
      else
        ok_json
          [
            ("stale", `Bool false);
            ("cursor", cursor_field cursor);
            ("ops", `List (List.filter_map Fun.id described));
          ])

  (* The backend cursor key lags, so fold it with the newest journal entry (what
     handle_changes_since reports) or the caller's starting anchor sits behind
     what changes_since would return. *)
  let handle_current_cursor () =
    let* keys = Fs.list_journal_keys () in
    let+ fetched = Fs.fetch_cursor () in
    ok_json [("cursor", cursor_field (newest_key ~init:fetched keys))]

  (* Content lives in the chunk store, not as a file. Writing straight to "dest"
     spares the caller a move it may not be permitted to make. *)
  let handle_ensure_cached ~dst_path key =
    let+ () = F.assemble_to key ~dst_path in
    ok_json [("localPath", `String dst_path)]

  (* The range served, not the one asked for: it is short at end of file. *)
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

  (* The file is adopted where it is: no copy, no chunking pass. Answered from
     the staged metadata, which is what will be published. *)
  let handle_write key staging_path =
    ignore (F.cancel_upload key);
    let* () = F.write_whole key ~src_path:staging_path in
    let* () = F.queue_put key in
    let+ resolved = F.resolve key in
    match resolved with
      | Some (`Staged (st, _)) ->
          ok_json
            [
              ("size", `Int (Int64.to_int st.Staged_manifest.s_size));
              ("mtime", `Float st.Staged_manifest.s_mtime);
            ]
      | Some (`Published m) ->
          (* Already uploaded and promoted. *)
          ok_json
            [
              ("size", `Int (Int64.to_int (Manifest.size m)));
              ("mtime", `Float (Manifest.mtime m));
            ]
      | None -> ok_json []

  let handle_delete key =
    let+ () = F.delete key in
    ok_json []

  let handle_rename src_key dst_key =
    let+ () = F.rename ~src:src_key ~dst:dst_key in
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

  (* A frontend names these by a path in whatever space it serves, so what it
     resolves to is its own to say. *)
  let with_frontend_path hooks path f =
    match hooks.path_to_key path with
      | Some key -> f key
      | None -> not_found path

  let handle_revert hooks key version =
    let version = if version = "" then None else Some version in
    let+ () = F.revert ?version key in
    hooks.changed key;
    ok_json []

  module Sh = Share.Make (C)

  (* Recovers the domain-relative path the share core expects from a full
     storage key. *)
  let handle_share key =
    let rel = Logical_key.path key in
    let expires = int_of_float (Unix.time ()) + (7 * 86400) in
    let+ result = Sh.create ~expires ~rel () in
    match result with
      | Ok url -> ok_json [("url", `String url)]
      | Error msg -> error_json msg

  (* The action strings are a wire contract with the FileProvider extension (see
     macos/TsyncFileProvider/IPC.swift): rename handlers freely, never these. *)

  (* Actions a read-only domain refuses here rather than trusting a frontend's
     advertised capabilities, which a direct request need not honour. Sharing is
     absent: a share manifest lives outside every domain root. *)
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
          (* [None] means the reference points at something no longer there,
             which is an answer, not a failure. *)
          let with_target_ref f =
            let t = target obj in
            let* key = resolve t in
            match key with
              | None -> not_found (Item_ref.to_string t)
              | Some key -> f t key
          in
          let with_target f = with_target_ref (fun _ key -> f key) in
          (* A container plus a leaf name. Key-speaking callers pass the whole
             key as "path". *)
          let with_destination f =
            match List.assoc_opt "parentRef" obj with
              | Some (`String s) -> (
                  let name = get_str obj "name" in
                  if name = "" then fail `Invalid "\"name\" is required"
                  else
                    let* parent = resolve (Ir.parse s) in
                    match parent with
                      | None -> not_found s
                      | Some parent ->
                          (* A parent names a folder because it is one, however
                             it was spelled: reading that off the reference is
                             how a caller got an exception for a missing
                             separator. *)
                          f
                            (Logical_key.file_in
                               (Lk.dir (Logical_key.path parent))
                               name))
              | _ -> (
                  match Option.map Lk.file (Lk.rel_of_string path) with
                    | Some key -> f key
                    | None -> not_found path)
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
                        (* Source is named as anywhere else; the target is a
                           destination. *)
                        let src_ref =
                          match List.assoc_opt "ref" obj with
                            | Some (`String s) -> Ir.parse s
                            | _ -> Ir.parse (get_str obj "src")
                        in
                        let* src = resolve src_ref in
                        match src with
                          | None -> not_found (Item_ref.to_string src_ref)
                          | Some src ->
                              with_destination (fun dst ->
                                  handle_rename src dst))
                    | "mkdir" ->
                        with_destination (fun key ->
                            handle_mkdir (Lk.dir (Logical_key.path key)))
                    | "symlink" ->
                        with_destination (fun key ->
                            handle_symlink key (get_str obj "target"))
                    | "rmdir" -> with_target handle_rmdir
                    | "share" -> with_target handle_share
                    (* From the CLI, which speaks in typed filesystem paths and
                       knows nothing about ids. *)
                    | "evict" ->
                        with_frontend_path hooks path (fun key ->
                            let+ () = hooks.evict key in
                            ok_json [])
                    | "restore" ->
                        with_frontend_path hooks path (fun key ->
                            let+ () = hooks.restore key in
                            ok_json [])
                    | "revert" ->
                        with_frontend_path hooks path (fun key ->
                            handle_revert hooks key (get_str obj "arg"))
                    | "full_resync" ->
                        let+ () = hooks.full_resync () in
                        ok_json []
                    (* Cheap by design: no store access, no backend health, so a
                       menu-bar poll costs one socket round trip. The whole
                       report is [stats]. *)
                    | "status" ->
                        (* The one store read here: where the bytes of an
                           in-flight upload are, so a previewer can look at
                           them. A handful of local reads, not a walk. *)
                        let+ uploading = F.uploads_in_flight () in
                        ok_json
                          (("domain", `String C.domain_name)
                          :: ("running", `Bool true)
                          :: ("paused", `Bool (F.uploads_paused ()))
                          :: ("pendingUploads", `Int (F.uploads_pending ()))
                          :: ( "pendingDownloads",
                               `Int (F.downloads_in_flight ()) )
                          :: ( "uploading",
                               `List
                                 (List.map
                                    (fun ({ name; rel; body; size } :
                                           File_ops.in_flight) ->
                                      `Assoc
                                        (("name", `String name)
                                         :: ("rel", `String rel)
                                         ::
                                           (match body with
                                           | Some body ->
                                               [("body", `String body)]
                                           | None -> [])
                                        @
                                          match size with
                                          | Some size ->
                                              [
                                                ( "size",
                                                  `Int (Int64.to_int size) );
                                              ]
                                          | None -> []))
                                    uploading) )
                          :: ("downloading", `List (downloading_json ()))
                          :: ( "pendingBytes",
                               `Int (Int64.to_int (F.uploads_pending_bytes ()))
                             )
                             (* Process-wide, not per domain: one uplink is
                                  what an ETA is against. *)
                          :: ("bytesUploaded", `Int (Metrics.uploaded ()))
                          :: ( "uploadBytesPerSec",
                               `Float (Metrics.upload_rate ()) )
                          :: hooks.status_fields ())
                    | "pause" ->
                        F.set_uploads_paused (get_str obj "arg" <> "off");
                        Lwt.return (ok_json [])
                    | "stats" ->
                        (* This daemon reports itself twice: at the top as the
                         answering process, and in the domain's [frontends] with
                         the queues only it knows, where a proxy asking over IPC
                         picks it up.

                         [arg] is a comma-separated set: [totals] reaches for the
                         store, [exact] counts every chunk instead of sampling
                         shards, [reload] recomputes, and [frontend] asks for
                         this frontend alone. *)
                        let flags =
                          String.split_on_char ',' (get_str obj "arg")
                        in
                        let has f = List.mem f flags in
                        let exact = has "exact" in
                        let reload = has "reload" in
                        let totals = has "totals" in
                        let frontend_only = has Status_report.frontend_only in
                        let* staged = F.staged_count () in
                        (* What this frontend knows and nobody else does. The
                         bounds it runs under are the domain's, reported
                         there. *)
                        let queues =
                          [
                            ("reachable", `Bool true);
                            ("pendingDownloads", `Int (F.downloads_in_flight ()));
                            ("downloading", `List (downloading_json ()));
                            ("stagedFiles", `Int staged);
                            ( "downloadsCompleted",
                              `Int (F.downloads_completed_count ()) );
                            (* Usual cause of a mount gone quiet while its
                             backends answer fine. *)
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
                        (* Frontends supply their name as [frontend]; entries use
                         [type], as backend entries do. Normalised once here so no
                         reader has to know both spellings. *)
                        let queues =
                          ("type", `String frontend_type)
                          :: List.remove_assoc "frontend" queues
                        in
                        let+ domain =
                          (* Under [frontend] the cache walk, the WAL read and a
                             probe of every backend are somebody else's: the
                             domain belongs to whoever converges it, and every
                             process answering for it is that work done again
                             for the same answer. *)
                          if frontend_only then
                            Lwt.return
                              (`Assoc
                                 [
                                   ("name", `String C.domain_name);
                                   ("frontends", `List [`Assoc queues]);
                                 ])
                          else
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
                    (* From whoever converges this domain, which is another
                       process and has no other way to reach the view a frontend
                       keeps. Not mutating: the ops are already applied and the
                       mirror already says so, and what this buys is only that
                       the frontend looks again. *)
                    | "changed" ->
                        (* A key the sender names and this domain cannot read
                           means the two disagree about the namespace, which is
                           worth hearing about rather than a shorter list. *)
                        let named k =
                          match Option.map Lk.file (Lk.rel_of_string k) with
                            | Some key -> Some key
                            | None ->
                                Log.warn "changed: not this domain's key %s" k;
                                None
                        in
                        List.iter hooks.changed
                          (match List.assoc_opt "keys" obj with
                            | Some (`List l) ->
                                List.filter_map
                                  (function `String k -> named k | _ -> None)
                                  l
                            | _ -> []);
                        Lwt.return (ok_json [])
                    | "stop" ->
                        hooks.on_stop ();
                        Lwt.return (ok_json [])
                    (* Answered here so the connection can be handed over; the
                     stream itself belongs to {!Ipc.serve}. *)
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
              (* The routed domain, not the requested name: equal by
                 construction, and this is the topic events publish under. *)
              | "subscribe" when get_str obj "domain" <> "" ->
                  `Subscribe C.domain_name
              | _ -> `Continue
          in
          Lwt.return (resp, ctl)
      | _ -> Lwt.return (error_json "expected JSON object", `Continue)
end
