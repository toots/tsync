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

(* Actions that change a domain: what a read-only domain refuses here rather
   than trusting a frontend's advertised capabilities, which a direct request
   need not honour, and what leaves an upload owed once accepted. Sharing is
   absent: a share manifest lives outside every domain root. *)
let mutating_actions =
  ["create"; "write"; "delete"; "rename"; "mkdir"; "rmdir"; "symlink"; "revert"]

let mutates line =
  match Yojson.Safe.from_string line with
    | `Assoc obj -> (
        match List.assoc_opt "action" obj with
          | Some (`String action) -> List.mem action mutating_actions
          | _ -> false)
    | _ | (exception _) -> false

module type S = sig
  type hooks = {
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
  val key_of_ref : string -> Logical_key.t option Lwt.t

  val item_ref : Logical_key.t -> string option Lwt.t

  val handler :
    hooks ->
    string ->
    (string * [ `Continue | `Stop | `Subscribe of string ]) Lwt.t
end

module Make
    (C : Conf_lwt.S)
    (F : File_ops.S with type 'a io := 'a Lwt.t)
    (Sq : Sync_queue.S with type 'a io := 'a Lwt.t) : S = struct
  module Diag = Diagnostics.Make (C)

  (* One mutation at a time. A reference is resolved to a path before the
     mutation takes the mirror's lock, so two requests in flight at once -- the
     File Provider sends them so -- could rename a folder and, resolved against
     its old path, drop a file into a folder that no longer existed there. *)
  let mutations = Lwt_mutex.create ()

  let serialized action f =
    if List.mem action mutating_actions then Lwt_mutex.with_lock mutations f
    else f ()

  type hooks = {
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

  let page_after obj = match get_str obj "after" with "" -> None | s -> Some s

  (* A request names its target by reference or, for the callers that predate
     them, by logical key. Everything below works in keys: references are
     resolved here and nowhere else. *)

  module Ir = Item_ref.Make (C)
  module Lk = Logical_key.Make (C)

  let key_of_id id =
    Folder_ids_lwt.key_of_id ~cache_root:C.cache_root ~domain_name:C.domain_name
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
    | `Bad _ -> Lwt.return_none

  (* The item a reference names, for a frontend command that works from the
     mirror rather than through a request. *)
  let key_of_ref s = resolve (Ir.parse s)

  let target obj =
    match List.assoc_opt "ref" obj with
      | Some (`String s) -> Ir.parse s
      | _ -> `Bad ""

  (* Rows, and the folder-id lookups that name them, live in {!Item_row}: a
     listing, a stat and a change all answer with one shape. *)
  module R = Item_row.Make (C) (F)

  let ref_str r = `String (Item_ref.to_string r)

  (* The id of a folder key, under two names because the call sites mean
     different things by it: one holds the directory, the other is climbing to
     a parent. *)
  let own_folder_id = R.own_folder_id
  let lookup_folder = R.own_folder_id
  let item_ref = R.item_ref

  (* Every reference says which kind it names, and {!handle_stat} holds it to
     that against the tree: a [f:] reference must not answer for a folder. *)
  let expected_kind = function
    | `File _ -> `File
    | `Dir _ | `Root -> `Dir
    | `Bad _ -> `Any

  let handle_stat ?(expect = `Any) key =
    let* row = R.of_key ~expect key in
    match row with
      | None -> not_found (Logical_key.to_string key)
      | Some row -> Lwt.return (ok_json (Item_row.fields row))

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

  (* What a caller that names no limit gets. Large enough that one which does
     not page still finishes in a call, small enough that no single reply is a
     folder's or a domain's whole history. *)
  let default_page_limit = 1000
  let default_changes_limit = 512

  let page_limit obj =
    Option.value (get_int obj "limit") ~default:default_page_limit

  (* One page of an ordered listing: the entries after [after], [limit] of them
     as rows, and the cursor to resume from when more follow.

     An entry is ordered by one string and resumed from by another, so that a
     listing can order by path and still hand out a cursor bounded like a
     reference. For one folder the two are the same name.

     By name and not by arrival, because the page cursor is the last entry
     served and nothing else: a caller resuming hands back a cursor, so a fresh
     process answers the same as the one that started, and an item added or
     removed between pages shifts nothing before it. An offset into a listing
     held in memory cannot promise either.

     Both of the system's initial-page sorts land here. What the contract turns
     on is that the order is the same across the pages of one enumeration, which
     a name gives whatever the caller meant to sort by. *)
  let page ?after ?(skipped = 0) ~limit ~label ~row entries =
    let entries =
      List.sort (fun (a, _, _) (b, _, _) -> compare (a : string) b) entries
    in
    let entries =
      match after with
        | None -> entries
        | Some a -> List.filter (fun (n, _, _) -> compare n a > 0) entries
    in
    (* One past the page, which is how the cursor is answered without asking
       whether the listing has more. *)
    let slice = List.filteri (fun i _ -> i <= limit) entries in
    let+ rows =
      Lwt_list.map_s
        (fun (_, _, e) -> row e)
        (List.filteri (fun i _ -> i < limit) slice)
    in
    let named = List.filter_map Fun.id rows in
    let unnamed = List.length rows - List.length named in
    let next =
      if List.length slice > limit then (
        match List.nth_opt slice (limit - 1) with
          | Some (_, cursor, _) -> [("next", `String cursor)]
          | None -> [])
      else []
    in
    ok_json
      ((("items", `List (List.map Item_row.to_json named)) :: next)
      @ unnamed_field label (unnamed + skipped))

  let row_of ~container_id = function
    | `File e -> R.of_listed ~container_id e
    | `Dir key -> R.of_dir ~container_id key

  (* The entries of one folder, each under its name and its key. *)
  let children ~container_id prefix =
    let+ files, dirs = F.list_children ~prefix in
    List.map
      (fun (e : Checkout.listed) ->
        let key = e.Checkout.key in
        (Logical_key.leaf key, key, (container_id, `File e)))
      files
    @ List.map
        (fun (d, _mtime) ->
          let key = Logical_key.dir_in prefix d in
          (d, key, (container_id, `Dir key)))
        dirs

  (* One page of a folder: one list, each entry tagged by kind, ordered by name.
     A reference names a folder or it does not reach here. *)
  let handle_list_dir ?after ~limit prefix =
    let* container = own_folder_id prefix in
    match container with
      | None -> not_found (Logical_key.to_string prefix)
      | Some container_id ->
          let* entries = children ~container_id prefix in
          page ?after ~limit
            ~label:(Logical_key.to_string prefix)
            ~row:(fun (container_id, e) -> row_of ~container_id e)
            (List.map (fun (name, _, e) -> (name, name, e)) entries)

  (* Every item of the domain in one order, a page at a time: what a frontend
     that must enumerate the whole domain asks for, with nothing held between
     pages. Ordered by path, resumed from "<container id>/<name>": a path can
     outgrow what a caller may hand back, a reference cannot.

     A cursor whose folder is gone places nothing, and the listing starts over:
     an item served twice costs a call, one skipped is never asked for again.

     A folder this client has no id for is unnamed like any row, and its
     subtree, which nothing could name, counts once more. *)
  let handle_list_all ?after ~limit () =
    let rec collect prefix (acc, unnamed) =
      let* container = own_folder_id prefix in
      match container with
        | None -> Lwt.return (acc, unnamed + 1)
        | Some container_id ->
            let* here = children ~container_id prefix in
            let acc =
              List.rev_append
                (List.map
                   (fun (name, key, e) ->
                     (Logical_key.path key, container_id ^ "/" ^ name, e))
                   here)
                acc
            in
            Lwt_list.fold_left_s
              (fun acc (_, _, (_, entry)) ->
                match entry with
                  | `Dir key -> collect key acc
                  | `File _ -> Lwt.return acc)
              (acc, unnamed) here
    in
    let* after =
      match Option.map (String.split_on_char '/') after with
        | Some [id; name] ->
            let+ key = resolve (`File (id, name)) in
            Option.map Logical_key.path key
        | _ -> Lwt.return_none
    in
    (* ponytail: the mirror is walked whole for every page; an index by path if
       a domain grows past what a readdir sweep can page. *)
    let* entries, skipped = collect Lk.root ([], 0) in
    page ?after ~skipped ~limit ~label:"list_all"
      ~row:(fun (container_id, e) -> row_of ~container_id e)
      entries

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

  (* An op names its item the way a listing does, and carries the whole of it.
     An entry is kept only once it has been applied, so for anything but a
     removal the mirror still holds the item and its row is read rather than
     rebuilt from the op — which is what lets a reader turn a batch of changes
     into items without a call per change.

     A removal has nothing left to read, so it carries the naming alone. That is
     all a deletion needs: what it names is going away.

     Every end is named through the lookup that outlives a path: an op is read
     back after the mirror has moved on, and the folder it spelled may since
     have been renamed or removed. The id it kept is what the reader knows the
     folder by, so the op names the right item either way. *)
  let op_to_json ~lookup op =
    let file_ref = file_ref ~lookup and dir_ref = dir_ref ~lookup in
    let parent_ref = parent_ref ~lookup in
    let described ~self ~parent ~fields key =
      match named self parent key with
        | None -> Lwt.return_none
        | Some naming ->
            let+ row =
              match (self, parent) with
                (* The op carries the folder's id, and everything a directory's
                   row says follows from it. Read back from the mirror instead
                   and a renamed folder answers nothing: the marker the lookup
                   wants moved with it. *)
                | Some (`Dir id), Some parent ->
                    Lwt.return_some
                      (Item_row.dir_with_id ~self:(`Dir id) ~parent
                         ~name:(Logical_key.leaf key) id)
                | _ ->
                    (* The item as it is now, found by its reference: the path
                       the op spelled may have moved with its folder since. *)
                    let* current =
                      match self with
                        | Some r -> resolve r
                        | None -> Lwt.return_none
                    in
                    R.of_key (Option.value current ~default:key)
            in
            let item =
              match row with
                | None -> []
                | Some row -> [("item", Item_row.to_json row)]
            in
            Some (`Assoc (fields @ naming @ item))
    in
    let removed ~self ~parent ~fields key =
      Lwt.return
        (Option.map
           (fun naming -> `Assoc (fields @ naming))
           (named self parent key))
    in
    match op with
      | `Put (rel, _) ->
          let key = Lk.file rel in
          let* self = file_ref key in
          let* parent = parent_ref key in
          described ~self ~parent ~fields:[("op", `String "put")] key
      | `Delete rel ->
          let key = Lk.file rel in
          let* self = file_ref key in
          let* parent = parent_ref key in
          removed ~self ~parent ~fields:[("op", `String "delete")] key
      | `Mkdir (rel, id) ->
          let key = Lk.dir rel in
          let* self = dir_ref key id in
          let* parent = parent_ref key in
          described ~self ~parent ~fields:[("op", `String "mkdir")] key
      | `Rmdir (rel, id) ->
          let key = Lk.dir rel in
          let* self = dir_ref key id in
          let* parent = parent_ref key in
          removed ~self ~parent
            ~fields:([("op", `String "rmdir")] @ dir_id_field id)
            key
      | `Rename { Journal.dst; src; is_dir; id; _ } -> (
          (* A directory keeps its id across a move, which is what marks the two
             paths as one folder. A file's reference changes, so name both ends —
             and both containers, since a reader deciding whether a move concerns
             it has to test the one it left as well as the one it arrived in. *)
          let as_key rel = if is_dir then Lk.dir rel else Lk.file rel in
          let dst = as_key dst and src = as_key src in
          let* self = if is_dir then dir_ref dst id else file_ref dst in
          let* parent = parent_ref dst in
          let* src_self = if is_dir then Lwt.return self else file_ref src in
          let* src_parent = parent_ref src in
          let fields =
            [("op", `String "rename"); ("is_dir", `Bool is_dir)]
            @ dir_id_field id
            @ (match src_self with
              | Some r -> [("srcRef", ref_str r)]
              | None -> [])
            @
              match src_parent with
              | Some r -> [("srcParentRef", ref_str r)]
              | None -> []
          in
          let+ described = described ~self ~parent ~fields dst in
          match (described, src_self) with
            | Some _, Some _ -> described
            (* Both ends have to be nameable or the move cannot be reported as
               one, and a half-reported move loses an item. *)
            | _ -> None)

  (* The wire carries the anchor as a string, [""] from a caller that has never
     synced. *)
  let cursor_field = function
    | Some c -> `String (Journal.Entry_key.to_string c)
    | None -> `String ""

  (* Named once: every call below passes the same pair. *)
  let cache_root = C.cache_root
  let domain_name = C.domain_name

  (* Answered from the entries this client has kept rather than from the store:
     the same keys, in the same order, but read locally and — because an entry is
     kept only once it is applied — never naming an item the mirror has yet to
     catch up with.

     Which is also why nothing is filtered by who wrote it. A change this client
     made is still a change every frontend but the one that made it has to hear
     about, and the client uuid is one per machine, so filtering on it hid what
     the CLI did from the mount. *)
  let handle_changes_since ~limit anchor =
    let anchor =
      if anchor = "" then None else Journal.Entry_key.of_string anchor
    in
    let* head = Applied_entries.head ~cache_root ~domain_name in
    let up_to_date =
      match (anchor, head) with
        | Some a, Some h -> Journal.Entry_key.compare a h = 0
        (* Nothing kept and nothing asked for: a domain that has not changed
           since this client first saw it, not a gap. *)
        | None, None -> true
        | _ -> false
    in
    if up_to_date then
      Lwt.return
        (ok_json
           [
             ("stale", `Bool false);
             ("cursor", cursor_field head);
             ("more", `Bool false);
             ("ops", `List []);
           ])
    else
      let* page =
        Applied_entries.since ~cache_root ~domain_name ?since:anchor ~limit ()
      in
      match page with
        (* The anchor is no longer kept, so no delta bridges it. *)
        | None -> Lwt.return (ok_json [("stale", `Bool true)])
        | Some page ->
            let entries = page.Applied_entries.entries in
            let ops = List.concat_map snd entries in
            (* Where the batch reached, which is not the head when it was capped.
           Holding at the anchor when nothing followed is what stops a caller
           being told to start over. *)
            let cursor =
              match List.rev entries with (k, _) :: _ -> Some k | [] -> anchor
            in
            let+ described =
              Lwt_list.map_s (op_to_json ~lookup:R.removed_folder_id) ops
            in
            (* A folder this client has no id for at all — the mirror and the folder
           index disagreeing, not a poller yet to catch up. The caller re-lists,
           which is the repair. *)
            if List.exists Option.is_none described then
              ok_json [("stale", `Bool true)]
            else
              ok_json
                [
                  ("stale", `Bool false);
                  ("cursor", cursor_field cursor);
                  ("more", `Bool page.Applied_entries.more);
                  ("ops", `List (List.filter_map Fun.id described));
                ]

  let handle_current_cursor () =
    let+ head = Applied_entries.head ~cache_root ~domain_name in
    ok_json [("cursor", cursor_field head)]

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

  (* What the item became, answered by the call that made it. A caller holding
     this needs no listing to find what it just created, which is the round trip
     a directory forced: only this side mints a folder id, so its reference
     cannot be composed the way a file's can. *)
  let with_item ?(fields = []) key =
    let+ row = R.of_key key in
    ok_json
      (fields
      @ match row with None -> [] | Some r -> [("item", Item_row.to_json r)])

  let handle_create key =
    let* () = F.create key in
    with_item key

  (* The file is adopted where it is: no copy, no chunking pass. Answered from
     the staged metadata, which is what will be published. *)
  let handle_write ~await key staging_path =
    ignore (F.cancel_upload key);
    let* () = F.write_whole key ~src_path:staging_path in
    let* () = F.queue_put key in
    (* [isUploaded] in the answer says how the wait ended. *)
    let* () = if await then Sq.wait_uploaded key else Lwt.return_unit in
    let* resolved = F.resolve key in
    let fields =
      match resolved with
        | Some (`Staged (st, _)) ->
            [
              ("size", `Int (Int64.to_int st.Staged_manifest.s_size));
              ("mtime", `Float st.Staged_manifest.s_mtime);
            ]
        (* Already uploaded and promoted. *)
        | Some (`Published m) ->
            [
              ("size", `Int (Int64.to_int (Manifest.size m)));
              ("mtime", `Float (Manifest.mtime m));
            ]
        | None -> []
    in
    with_item ~fields key

  let handle_delete key =
    let+ () = F.delete key in
    ok_json []

  (* The destination, since that is what the caller now holds. *)
  let handle_rename src_key dst_key =
    let* () = F.rename ~src:src_key ~dst:dst_key in
    with_item dst_key

  let handle_mkdir key =
    let* () = F.mkdir key in
    with_item key

  let handle_symlink key target =
    let* () = F.symlink ~target key in
    with_item key

  let handle_rmdir key =
    let+ () = F.rmdir key in
    ok_json []

  let handle_revert hooks key version =
    let version = if version = "" then None else Some version in
    let+ () = F.revert ?version key in
    hooks.changed key;
    ok_json []

  module Sh = Share_lwt.Make (C)

  (* A domain-relative path is the whole of what the share core needs: it never
     asks whether the target is a file or a folder. *)
  let handle_share rel =
    let expires = int_of_float (Unix.time ()) + (7 * 86400) in
    let+ result = Sh.create ~expires ~rel () in
    match result with
      | Ok url -> ok_json [("url", `String url)]
      | Error msg -> error_json msg

  (* The action strings are a wire contract with the FileProvider extension (see
     macos/TsyncFileProvider/IPC.swift): rename handlers freely, never these. *)

  let handler hooks line =
    match Yojson.Safe.from_string line with
      | exception _ ->
          Lwt.return (error_code_json `Invalid "invalid JSON", `Continue)
      | `Assoc obj ->
          let action = get_str obj "action" in
          (* [None] means the reference points at something no longer there,
             which is an answer, not a failure. *)
          let with_target_ref f =
            match target obj with
              | `Bad "" -> fail `Invalid "\"ref\" is required"
              | t -> (
                  let* key = resolve t in
                  match key with
                    | None -> not_found (Item_ref.to_string t)
                    | Some key -> f t key)
          in
          let with_target f = with_target_ref (fun _ key -> f key) in
          (* The folder and the leaf, not a key: which kind is being made is the
             action's to say, and only it knows. *)
          let with_destination f =
            match List.assoc_opt "parentRef" obj with
              | Some (`String s) -> (
                  let name = get_str obj "name" in
                  if name = "" then fail `Invalid "\"name\" is required"
                  else
                    let* parent = resolve (Ir.parse s) in
                    match parent with
                      | None -> not_found s
                      | Some parent -> f parent name)
              | _ -> fail `Invalid "\"parentRef\" and \"name\" are required"
          in
          let with_file_destination f =
            with_destination (fun parent name ->
                f (Logical_key.file_in parent name))
          in
          let* resp =
            Lwt.catch
              (fun () ->
                if C.read_only && List.mem action mutating_actions then
                  fail `Read_only
                    (Printf.sprintf "'%s' is read-only" C.domain_name)
                else
                  serialized action (fun () ->
                      match action with
                        | "stat" ->
                            with_target_ref (fun t key ->
                                handle_stat ~expect:(expected_kind t) key)
                        | "list_dir" ->
                            with_target
                              (handle_list_dir ?after:(page_after obj)
                                 ~limit:(page_limit obj))
                        | "list_all" ->
                            handle_list_all ?after:(page_after obj)
                              ~limit:(page_limit obj) ()
                        | "changes_since" ->
                            handle_changes_since
                              ~limit:
                                (Option.value (get_int obj "limit")
                                   ~default:default_changes_limit)
                              (get_str obj "arg")
                        | "cursor" -> handle_current_cursor ()
                        | "ensure_cached" -> (
                            match get_str obj "dest" with
                              | "" ->
                                  fail `Invalid
                                    "ensure_cached requires \"dest\""
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
                                    "fetch_range requires \"offset\" and \
                                     \"length\""
                              | _, Some offset, Some length
                                when offset < 0 || length <= 0 ->
                                  fail `Invalid
                                    "fetch_range needs a non-negative \
                                     \"offset\" and a positive \"length\""
                              | dst_path, Some offset, Some length ->
                                  with_target
                                    (handle_fetch_range ~dst_path ~offset
                                       ~length))
                        | "create" -> with_file_destination handle_create
                        | "write" ->
                            with_file_destination (fun key ->
                                handle_write
                                  ~await:
                                    (List.assoc_opt "await" obj
                                    = Some (`Bool true))
                                  key (get_str obj "staging"))
                        | "delete" -> with_target handle_delete
                        | "rename" -> (
                            (* Source is named as anywhere else; the target is a
                           destination. *)
                            let src_ref = target obj in
                            let* src = resolve src_ref in
                            match src with
                              | None -> not_found (Item_ref.to_string src_ref)
                              | Some src ->
                                  (* A rename keeps the kind it moves: a folder
                                 stays one, and its id travels with it. *)
                                  with_destination (fun parent name ->
                                      handle_rename src
                                        (if Logical_key.kind src = `Dir then
                                           Logical_key.dir_in parent name
                                         else Logical_key.file_in parent name)))
                        | "mkdir" ->
                            with_destination (fun parent name ->
                                handle_mkdir (Logical_key.dir_in parent name))
                        | "symlink" ->
                            with_file_destination (fun key ->
                                handle_symlink key (get_str obj "target"))
                        | "rmdir" -> with_target handle_rmdir
                        (* A caller holding a real path names it directly, which
                       skips the folder resolution a reference costs. *)
                        | "share" -> (
                            match List.assoc_opt "rel" obj with
                              | Some (`String rel) -> handle_share rel
                              | _ ->
                                  with_target (fun key ->
                                      handle_share (Logical_key.path key)))
                        | "evict" ->
                            with_target (fun key ->
                                let+ () = hooks.evict key in
                                ok_json [])
                        | "restore" ->
                            with_target (fun key ->
                                let+ () = hooks.restore key in
                                ok_json [])
                        | "revert" ->
                            with_target (fun key ->
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
                              :: ("paused", `Bool (Sq.paused ()))
                              :: ("pendingUploads", `Int (Sq.pending ()))
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
                                                      `Int (Int64.to_int size)
                                                    );
                                                  ]
                                              | None -> []))
                                        uploading) )
                              :: ("downloading", `List (downloading_json ()))
                              :: ( "pendingBytes",
                                   `Int (Int64.to_int (Sq.pending_bytes ())) )
                                 (* Process-wide, not per domain: one uplink is
                                  what an ETA is against. *)
                              :: ("bytesUploaded", `Int (Metrics.uploaded ()))
                              :: ( "uploadBytesPerSec",
                                   `Float (Metrics.upload_rate ()) )
                              :: hooks.status_fields ())
                        | "pause" ->
                            Sq.set_paused (get_str obj "arg" <> "off");
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
                            let frontend_only =
                              has Status_report.frontend_only
                            in
                            let* staged = F.staged_count () in
                            (* What this frontend knows and nobody else does. The
                         bounds it runs under are the domain's, reported
                         there. *)
                            let queues =
                              [
                                ("reachable", `Bool true);
                                ( "pendingDownloads",
                                  `Int (F.downloads_in_flight ()) );
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
                                    Log.warn "changed: not this domain's key %s"
                                      k;
                                    None
                            in
                            List.iter hooks.changed
                              (match List.assoc_opt "keys" obj with
                                | Some (`List l) ->
                                    List.filter_map
                                      (function
                                        | `String k -> named k | _ -> None)
                                      l
                                | _ -> []);
                            Lwt.return (ok_json [])
                        | "stop" ->
                            hooks.on_stop ();
                            Lwt.return (ok_json [])
                        (* Answered here so the connection can be handed over; the
                     stream itself belongs to {!Ipc_lwt.serve}. *)
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
