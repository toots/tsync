open Lwt.Syntax

module Make (C : Conf.S) (F : File.S) = struct
  module Fs = File_store.Make (C)
  module J = Journal.Make (C)

  type hooks = {
    path_to_key : string -> string;
    request_evict : string -> unit Lwt.t;
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

  let error_json msg =
    Yojson.Safe.to_string (`Assoc [("ok", `Bool false); ("error", `String msg)])

  let get_str obj key =
    match List.assoc_opt key obj with Some (`String s) -> s | _ -> ""

  (* ── File operation handlers ──────────────────────────────────────────── *)

  let stat_opt path =
    Lwt.catch
      (fun () ->
        let+ st = Lwt_unix_retry.LargeFile.stat path in
        Some st)
      (fun _ -> Lwt.return_none)

  (* Resolve the manifest once (local sidecar, else a single backend GET) and
     derive size, mtime, etag and upload state from it. Going through F.stat
     plus a separate etag lookup would fetch the same manifest up to twice
     more per call, and fileproviderd stats items constantly. *)
  let handle_stat key =
    let* mst = stat_opt (F.manifest_path key) in
    match mst with
      | Some { Unix.LargeFile.st_kind = Unix.S_DIR; _ } ->
          Lwt.return
            (ok_json
               [
                 ("size", `Int 0);
                 ("mtime", `Float (Unix.gettimeofday ()));
                 ("etag", `String "");
                 ("isUploaded", `Bool true);
               ])
      | _ -> (
          let* m = F.resolved_manifest key in
          match m with
            | Some (`Clean m) ->
                let fields =
                  [
                    ("size", `Int (Int64.to_int m.Manifest.size));
                    ("mtime", `Float m.Manifest.mtime);
                    ("etag", `String m.Manifest.h1);
                    ("isUploaded", `Bool true);
                  ]
                  @
                    match m.Manifest.symlink with
                    | None -> []
                    | Some t -> [("symlinkTarget", `String t)]
                in
                Lwt.return (ok_json fields)
            | Some `Dirty -> (
                let* st = stat_opt (F.local_path key) in
                match st with
                  | Some st ->
                      Lwt.return
                        (ok_json
                           [
                             ( "size",
                               `Int (Int64.to_int st.Unix.LargeFile.st_size) );
                             ("mtime", `Float st.Unix.LargeFile.st_mtime);
                             ("etag", `String "");
                             ("isUploaded", `Bool false);
                           ])
                  | None -> Lwt.return (error_json "not found"))
            | None -> Lwt.return (error_json "not found"))

  (* The listed objects are manifests, so their backend size/mtime are the manifest's,
     not the file's. Resolve the manifest (local sidecar, else fetched from the backend)
     to report the real logical size/mtime and the content hash (h1) as the etag — the
     same identity stat returns. Dirty or unknown files have no clean hash: fall back to
     the backend metadata with an empty etag. *)
  (* Bounds concurrent per-file manifest resolutions during enumeration. *)
  let resolve_pool =
    Lwt_pool.create (max 1 C.max_downloads) (fun () -> Lwt.return_unit)

  let file_entry_json (e : Backend.file_entry) =
    Lwt_pool.use resolve_pool @@ fun () ->
    let+ m = F.resolved_manifest e.key in
    let key = ("key", `String e.key) in
    match m with
      | Some (`Clean m) ->
          let fields =
            [
              key;
              ("size", `Int (Int64.to_int m.Manifest.size));
              ("mtime", `Float m.Manifest.mtime);
              ("etag", `String m.Manifest.h1);
            ]
            @
              match m.Manifest.symlink with
              | None -> []
              | Some t -> [("symlinkTarget", `String t)]
          in
          `Assoc fields
      | _ ->
          `Assoc
            [
              key;
              ("size", `Int e.size);
              ("mtime", `Float e.last_modified);
              ("etag", `String "");
            ]

  let handle_list_dir prefix =
    let* files, dirs = F.list_directory ~prefix in
    (* map_p: uncached entries each cost a backend GET; resolving them
       sequentially made cold enumeration O(files) round trips end-to-end.
       [resolve_pool] bounds the fan-out; map_p preserves result order. *)
    let+ files_json = Lwt_list.map_p file_entry_json files in
    (* Emit directories as full keys ending in "/", the same representation used by
       list_all and the change journal — one identity per directory everywhere. *)
    ok_json
      [
        ( "dirs",
          `List
            (List.map
               (fun (d, mtime) ->
                 let fields = [("key", `String (prefix ^ d ^ "/"))] in
                 let fields =
                   match mtime with
                     | None -> fields
                     | Some t -> fields @ [("mtime", `Float t)]
                 in
                 `Assoc fields)
               dirs) );
        ("files", `List files_json);
      ]

  let handle_list_all prefix =
    let* files = F.list_all_files ~prefix in
    let+ files_json = Lwt_list.map_p file_entry_json files in
    ok_json [("files", `List files_json)]

  (* ── Change feed (journal delta) ──────────────────────────────────────── *)

  (* Journal keys are relative to the domain prefix; the FileProvider uses full
     keys as item identifiers, with directories ending in "/". *)
  let full_key ?(dir = false) rel =
    let k = C.domain_prefix ^ rel in
    if dir && not (String.length k > 0 && k.[String.length k - 1] = '/') then
      k ^ "/"
    else k

  let op_to_json = function
    | `Put (key, size) ->
        `Assoc
          [
            ("op", `String "put");
            ("key", `String (full_key key));
            ("size", `Int (Int64.to_int size));
          ]
    | `Delete key ->
        `Assoc [("op", `String "delete"); ("key", `String (full_key key))]
    | `Mkdir key ->
        `Assoc
          [("op", `String "mkdir"); ("key", `String (full_key ~dir:true key))]
    | `Rmdir key ->
        `Assoc
          [("op", `String "rmdir"); ("key", `String (full_key ~dir:true key))]
    | `Rename { Journal.dst; src; is_dir; _ } ->
        `Assoc
          [
            ("op", `String "rename");
            ("key", `String (full_key ~dir:is_dir dst));
            ("src", `String (full_key ~dir:is_dir src));
            ("is_dir", `Bool is_dir);
          ]

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
      let+ ops_lists =
        Lwt_list.map_s (fun (ek, _) -> Fs.get_journal_entry ek) foreign
      in
      let ops =
        List.concat_map (function Some o -> o | None -> []) ops_lists
      in
      ok_json
        [
          ("stale", `Bool false);
          ("cursor", `String cursor);
          ("ops", `List (List.map op_to_json ops));
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

  let handle_ensure_cached key =
    let+ () = F.ensure_cached key in
    ok_json [("localPath", `String (F.local_path key))]

  let handle_create key =
    let+ () = F.create key in
    ok_json []

  let handle_write key staging_path =
    ignore (F.cancel_upload key);
    let* () = F.ensure_parent_dir key in
    let* () = Lwt_unix_retry.rename staging_path (F.local_path key) in
    let* () = F.mark_dirty key in
    let* () = F.queue_put key in
    let* st =
      Lwt.catch
        (fun () ->
          let+ st = Lwt_unix_retry.LargeFile.stat (F.local_path key) in
          Some st)
        (fun _ -> Lwt.return_none)
    in
    match st with
      | Some st ->
          Lwt.return
            (ok_json
               [
                 ("size", `Int (Int64.to_int st.Unix.LargeFile.st_size));
                 ("mtime", `Float st.Unix.LargeFile.st_mtime);
               ])
      | None -> Lwt.return (ok_json [])

  let handle_delete key =
    let+ () = F.delete key in
    ok_json []

  let strip_trailing_slash k =
    if String.length k > 0 && k.[String.length k - 1] = '/' then
      String.sub k 0 (String.length k - 1)
    else k

  let handle_rename src_key dst_key =
    let+ () =
      F.rename
        ~src:(strip_trailing_slash src_key)
        ~dst:(strip_trailing_slash dst_key)
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

  (* ── Dispatch ─────────────────────────────────────────────────────────── *)

  let handler hooks line =
    match Yojson.Safe.from_string line with
      | exception _ -> Lwt.return (error_json "invalid JSON", `Continue)
      | `Assoc obj ->
          let action = get_str obj "action" in
          let path = get_str obj "path" in
          let* resp =
            Lwt.catch
              (fun () ->
                match action with
                  | "stat" -> handle_stat path
                  | "list_dir" -> handle_list_dir path
                  | "list_all" -> handle_list_all path
                  | "changes_since" -> handle_changes_since (get_str obj "arg")
                  | "cursor" -> handle_current_cursor ()
                  | "ensure_cached" -> handle_ensure_cached path
                  | "create" -> handle_create path
                  | "write" -> handle_write path (get_str obj "staging")
                  | "delete" -> handle_delete path
                  | "rename" -> handle_rename (get_str obj "src") path
                  | "mkdir" -> handle_mkdir path
                  | "symlink" -> handle_symlink path (get_str obj "target")
                  | "rmdir" -> handle_rmdir path
                  | "evict" ->
                      let+ () = hooks.request_evict (hooks.path_to_key path) in
                      ok_json []
                  | "restore" ->
                      let+ () = hooks.restore (hooks.path_to_key path) in
                      ok_json []
                  | "revert" ->
                      handle_revert hooks (hooks.path_to_key path)
                        (get_str obj "arg")
                  | "auto_evict" ->
                      let result =
                        Ipc.handle_auto_evict ~data_dir:C.data_dir
                          (get_str obj "arg")
                      in
                      Lwt.return (ok_json [("result", `String result)])
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
                      let rate f = `Int (int_of_float (f ())) in
                      Lwt.return
                        (ok_json
                           ([
                              ("pendingDownloads", `Int (F.downloading_count ()));
                              ("dirtyFiles", `Int (F.dirty_count ()));
                              ("openFiles", `Int (F.open_files_count ()));
                              ( "downloadsCompleted",
                                `Int (F.downloads_completed_count ()) );
                              ("maxUploads", `Int C.max_uploads);
                              ("maxDownloads", `Int C.max_downloads);
                              ("bytesUploaded", `Int (Metrics.uploaded ()));
                              ("bytesDownloaded", `Int (Metrics.downloaded ()));
                              ("uploadBytesPerSec", rate Metrics.upload_rate);
                              ("downloadBytesPerSec", rate Metrics.download_rate);
                              ("chunksHashed", `Int (Metrics.hashed ()));
                              ("hashesPerSec", rate Metrics.hash_rate);
                              ("cpuSeconds", `Float (Metrics.cpu_seconds ()));
                              ("rssBytes", `Int (Metrics.rss_bytes ()));
                            ]
                           @ hooks.stats_fields ()))
                  | "download_progress" ->
                      Lwt.return
                        (match F.download_progress path with
                          | None -> ok_json [("active", `Bool false)]
                          | Some (done_, total) ->
                              ok_json
                                [
                                  ("active", `Bool true);
                                  ("bytesDownloaded", `Int done_);
                                  ("totalBytes", `Int total);
                                ])
                  | "stop" ->
                      hooks.on_stop ();
                      Lwt.return (ok_json [])
                  | _ -> Lwt.return (error_json ("unknown action: " ^ action)))
              (fun exn -> Lwt.return (error_json (Printexc.to_string exn)))
          in
          let ctl = match action with "stop" -> `Stop | _ -> `Continue in
          Lwt.return (resp, ctl)
      | _ -> Lwt.return (error_json "expected JSON object", `Continue)
end
