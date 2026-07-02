module Make (C : Conf.S) (F : File.S) = struct
  module Fs = File_store.Make (C)

  type hooks = {
    path_to_key : string -> string;
    request_evict : string -> unit;
    restore : string -> unit;
    changed : string -> unit;
    full_resync : unit -> unit;
    status_fields : unit -> (string * Yojson.Safe.t) list;
    on_stop : unit -> unit;
  }

  (* ── JSON helpers ─────────────────────────────────────────────────────── *)

  let ok_json fields =
    Yojson.Safe.to_string (`Assoc (("ok", `Bool true) :: fields))

  let error_json msg =
    Yojson.Safe.to_string (`Assoc [("ok", `Bool false); ("error", `String msg)])

  let get_str obj key =
    match List.assoc_opt key obj with Some (`String s) -> s | _ -> ""

  (* ── File operation handlers ──────────────────────────────────────────── *)

  let file_etag key =
    match F.read_manifest key with Some (`Clean m) -> m.Manifest.h1 | _ -> ""

  let handle_stat key =
    match F.stat key with
      | Some st ->
          let is_dirty =
            match F.read_manifest key with Some `Dirty -> true | _ -> false
          in
          ok_json
            [
              ("size", `Int (Int64.to_int st.Unix.LargeFile.st_size));
              ("mtime", `Float st.Unix.LargeFile.st_mtime);
              ("etag", `String (file_etag key));
              ("isUploaded", `Bool (not is_dirty));
            ]
      | None -> (
          match Fs.head_opt ~key with
            | None -> error_json "not found"
            | Some (e : Backend.file_entry) ->
                ok_json
                  [
                    ("size", `Int e.size);
                    ("mtime", `Float e.last_modified);
                    ("etag", `Null);
                    ("isUploaded", `Bool true);
                  ])

  let file_entry_json (e : Backend.file_entry) =
    `Assoc
      [
        ("key", `String e.key);
        ("size", `Int e.size);
        ("mtime", `Float e.last_modified);
      ]

  let handle_list_dir prefix =
    let files, dirs = Fs.list_directory ~prefix in
    ok_json
      [
        ("dirs", `List (List.map (fun d -> `String d) dirs));
        ("files", `List (List.map file_entry_json files));
      ]

  let handle_list_all prefix =
    let files = Fs.list_all_files ~prefix in
    ok_json [("files", `List (List.map file_entry_json files))]

  let handle_ensure_cached key =
    F.ensure_cached key;
    ok_json [("localPath", `String (F.local_path key))]

  let handle_create key =
    F.create key;
    ok_json []

  let handle_write key staging_path =
    ignore (F.cancel_upload key);
    F.ensure_parent_dir key;
    Unix.rename staging_path (F.local_path key);
    F.mark_dirty key;
    F.queue_put key;
    match
      try Some (Unix.LargeFile.stat (F.local_path key)) with _ -> None
    with
      | Some st ->
          ok_json
            [
              ("size", `Int (Int64.to_int st.Unix.LargeFile.st_size));
              ("mtime", `Float st.Unix.LargeFile.st_mtime);
            ]
      | None -> ok_json []

  let handle_delete key =
    F.delete key;
    ok_json []

  let strip_trailing_slash k =
    if String.length k > 0 && k.[String.length k - 1] = '/' then
      String.sub k 0 (String.length k - 1)
    else k

  let handle_rename src_key dst_key =
    F.rename
      ~src:(strip_trailing_slash src_key)
      ~dst:(strip_trailing_slash dst_key);
    ok_json []

  let handle_mkdir key =
    F.mkdir key;
    ok_json []

  let handle_rmdir key =
    F.rmdir key;
    ok_json []

  let handle_revert hooks key version =
    let version = if version = "" then None else Some version in
    F.revert ?version key;
    hooks.changed key;
    ok_json []

  (* ── Dispatch ─────────────────────────────────────────────────────────── *)

  let handler hooks line =
    match Yojson.Safe.from_string line with
      | exception _ -> (error_json "invalid JSON", `Continue)
      | `Assoc obj ->
          let action = get_str obj "action" in
          let path = get_str obj "path" in
          let resp =
            try
              match action with
                | "stat" -> handle_stat path
                | "list_dir" -> handle_list_dir path
                | "list_all" -> handle_list_all path
                | "ensure_cached" -> handle_ensure_cached path
                | "create" -> handle_create path
                | "write" -> handle_write path (get_str obj "staging")
                | "delete" -> handle_delete path
                | "rename" -> handle_rename (get_str obj "src") path
                | "mkdir" -> handle_mkdir path
                | "rmdir" -> handle_rmdir path
                | "evict" ->
                    hooks.request_evict (hooks.path_to_key path);
                    ok_json []
                | "restore" ->
                    hooks.restore (hooks.path_to_key path);
                    ok_json []
                | "revert" ->
                    handle_revert hooks (hooks.path_to_key path)
                      (get_str obj "arg")
                | "auto_evict" ->
                    let result =
                      Ipc.handle_auto_evict ~data_dir:C.data_dir
                        (get_str obj "arg")
                    in
                    ok_json [("result", `String result)]
                | "full_resync" ->
                    hooks.full_resync ();
                    ok_json []
                | "status" ->
                    ok_json
                      (("domain", `String C.domain_name)
                      :: ("running", `Bool true)
                      :: hooks.status_fields ())
                | "stop" ->
                    hooks.on_stop ();
                    ok_json []
                | _ -> error_json ("unknown action: " ^ action)
            with exn -> error_json (Printexc.to_string exn)
          in
          let ctl = match action with "stop" -> `Stop | _ -> `Continue in
          (resp, ctl)
      | _ -> (error_json "expected JSON object", `Continue)
end
