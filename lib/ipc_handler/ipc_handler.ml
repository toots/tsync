open Lwt.Syntax

module Make (C : Conf.S) (F : File.S) = struct
  module Fs = File_store.Make (C)

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

  let file_etag key =
    let+ m = F.read_manifest key in
    match m with Some (`Clean m) -> m.Manifest.h1 | _ -> ""

  let handle_stat key =
    let* st = F.stat key in
    match st with
      | Some st ->
          let* m = F.read_manifest key in
          let is_dirty = match m with Some `Dirty -> true | _ -> false in
          let+ etag = file_etag key in
          ok_json
            [
              ("size", `Int (Int64.to_int st.Unix.LargeFile.st_size));
              ("mtime", `Float st.Unix.LargeFile.st_mtime);
              ("etag", `String etag);
              ("isUploaded", `Bool (not is_dirty));
            ]
      | None -> (
          let+ head = Fs.head_opt ~key in
          match head with
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
    let+ files, dirs = Fs.list_directory ~prefix in
    ok_json
      [
        ("dirs", `List (List.map (fun d -> `String d) dirs));
        ("files", `List (List.map file_entry_json files));
      ]

  let handle_list_all prefix =
    let+ files = Fs.list_all_files ~prefix in
    ok_json [("files", `List (List.map file_entry_json files))]

  let handle_ensure_cached key =
    let+ () = F.ensure_cached key in
    ok_json [("localPath", `String (F.local_path key))]

  let handle_create key =
    let+ () = F.create key in
    ok_json []

  let handle_write key staging_path =
    ignore (F.cancel_upload key);
    let* () = F.ensure_parent_dir key in
    let* () = Lwt_unix.rename staging_path (F.local_path key) in
    let* () = F.mark_dirty key in
    let* () = F.queue_put key in
    let* st =
      Lwt.catch
        (fun () ->
          let+ st = Lwt_unix.LargeFile.stat (F.local_path key) in
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
                  | "ensure_cached" -> handle_ensure_cached path
                  | "create" -> handle_create path
                  | "write" -> handle_write path (get_str obj "staging")
                  | "delete" -> handle_delete path
                  | "rename" -> handle_rename (get_str obj "src") path
                  | "mkdir" -> handle_mkdir path
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
                      Lwt.return
                        (ok_json
                           ([
                              ( "pendingDownloads",
                                `Int (F.downloading_count ()) );
                              ("dirtyFiles", `Int (F.dirty_count ()));
                              ("openFiles", `Int (F.open_files_count ()));
                              ( "downloadsCompleted",
                                `Int (F.downloads_completed_count ()) );
                              ("maxUploads", `Int C.max_uploads);
                              ("maxDownloads", `Int C.max_downloads);
                            ]
                           @ hooks.stats_fields ()))
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
