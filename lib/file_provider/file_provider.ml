module Make(C : Conf.S) = struct
  module Sq = Sync_queue.Make(C)
  module F = File.Make(C)(Sq)
  module Fs = File_store.Make(C)

  (* ── Key helpers ──────────────────────────────────────────────────────── *)

  let path_to_key path =
    let path =
      if String.length path >= 2 && path.[0] = '~' && path.[1] = '/' then
        Sys.getenv "HOME" ^ String.sub path 1 (String.length path - 1)
      else path
    in
    let strip_prefix prefix s =
      let n = String.length prefix in
      if String.length s >= n && String.sub s 0 n = prefix then
        let rest = String.sub s n (String.length s - n) in
        Some
          (if String.length rest > 0 && rest.[0] = '/' then
             String.sub rest 1 (String.length rest - 1)
           else rest)
      else None
    in
    let rel =
      match strip_prefix C.data_dir path with
        | Some r -> r
        | None ->
            let cloud_root =
              Filename.concat (Sys.getenv "HOME") "Library/CloudStorage"
            in
            let found = ref None in
            (try
               Array.iter
                 (fun d ->
                   if !found = None then
                     found :=
                       strip_prefix (Filename.concat cloud_root d) path)
                 (Sys.readdir cloud_root)
             with _ -> ());
            (match !found with
              | Some r -> r
              | None ->
                  if path = "/" then ""
                  else if path.[0] = '/' then
                    String.sub path 1 (String.length path - 1)
                  else path)
    in
    C.domain_prefix ^ rel

  (* ── JSON helpers ─────────────────────────────────────────────────────── *)

  let ok_json fields =
    Yojson.Safe.to_string (`Assoc (("ok", `Bool true) :: fields))

  let error_json msg =
    Yojson.Safe.to_string
      (`Assoc [("ok", `Bool false); ("error", `String msg)])

  let get_str obj key =
    match List.assoc_opt key obj with
      | Some (`String s) -> s
      | _ -> ""

  let file_etag key =
    match F.read_manifest key with
      | Some (`Clean m) -> m.Manifest.h1
      | _ -> ""

  (* ── JSON handlers ────────────────────────────────────────────────────── *)

  let handle_stat key =
    match F.stat key with
      | Some st ->
          let is_dirty =
            match F.read_manifest key with
              | Some `Dirty -> true
              | _ -> false
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
            | Some (e : S3_client.file_entry) ->
                ok_json
                  [
                    ("size", `Int e.size);
                    ("mtime", `Float e.last_modified);
                    ("etag", `Null);
                    ("isUploaded", `Bool true);
                  ])

  let file_entry_json (e : S3_client.file_entry) =
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
    ok_json ["files", `List (List.map file_entry_json files)]

  let handle_ensure_cached key =
    F.ensure_cached key;
    ok_json ["localPath", `String (F.local_path key)]

  let handle_create key =
    F.create key;
    ok_json []

  let handle_write key staging_path =
    ignore (F.cancel_upload key);
    F.ensure_parent_dir key;
    Unix.rename staging_path (F.local_path key);
    F.mark_dirty key;
    F.queue_put key;
    match (try Some (Unix.LargeFile.stat (F.local_path key)) with _ -> None) with
      | Some st ->
          ok_json
            [
              ("size", `Int (Int64.to_int st.Unix.LargeFile.st_size));
              ("mtime", `Float st.Unix.LargeFile.st_mtime);
            ]
      | None -> ok_json []

  let handle_evict key =
    F.evict key;
    ok_json []

  let handle_delete key =
    F.delete key;
    ok_json []

  let strip_trailing_slash k =
    if String.length k > 0 && k.[String.length k - 1] = '/' then
      String.sub k 0 (String.length k - 1)
    else k

  let handle_rename src_key dst_key =
    F.rename ~src:(strip_trailing_slash src_key) ~dst:(strip_trailing_slash dst_key);
    ok_json []

  let handle_mkdir key =
    F.mkdir key;
    ok_json []

  let handle_rmdir key =
    F.rmdir key;
    ok_json []

  let json_handler line =
    match Yojson.Safe.from_string line with
      | exception _ -> error_json "invalid JSON"
      | `Assoc obj ->
          let action = get_str obj "action" in
          let path = get_str obj "path" in
          (try
             match action with
               | "stat" -> handle_stat path
               | "list_dir" -> handle_list_dir path
               | "list_all" -> handle_list_all path
               | "ensure_cached" -> handle_ensure_cached path
               | "create" -> handle_create path
               | "write" -> handle_write path (get_str obj "staging")
               | "evict" -> handle_evict path
               | "delete" -> handle_delete path
               | "rename" -> handle_rename (get_str obj "src") path
               | "mkdir" -> handle_mkdir path
               | "rmdir" -> handle_rmdir path
               | _ -> error_json ("unknown action: " ^ action)
           with exn -> error_json (Printexc.to_string exn))
      | _ -> error_json "expected JSON object"

  (* ── CLI IPC handler ──────────────────────────────────────────────────── *)

  let cli_handler line =
    match Ipc.parse_command line with
      | Stop -> "STOP"
      | Status ->
          Printf.sprintf {|STATUS {"domain":"%s","running":true}|} C.domain_name
      | Evict arg ->
          let key = path_to_key arg in
          F.evict key;
          Ipc.notify_evict ~path:C.notify_path key;
          "OK"
      | Restore arg ->
          let key = path_to_key arg in
          (try
             F.ensure_cached key;
             "OK"
           with exn -> "ERROR " ^ Printexc.to_string exn)
      | Auto_evict arg -> (
          match arg with
            | "on" ->
                F.auto_evict := true;
                "OK"
            | "off" ->
                F.auto_evict := false;
                "OK"
            | _ -> if !(F.auto_evict) then "on" else "off")
      | Full_resync ->
          (* ponytail: signal FileProvider extension to re-enumerate *)
          "OK"
      | exception Failure msg -> msg

  let dispatch_handler line =
    if String.length line > 0 && line.[0] = '{' then json_handler line
    else cli_handler line

  let mount _mount_point =
    F.auto_evict := true;
    Sq.start
      ~upload:(fun ~key ~cancel -> F.upload ~cancel key)
      ~on_version:(fun ~entry_key:_ -> ())
      ~on_upload_done:(fun ~key ->
        F.on_upload_done key;
        Ipc.notify_uploaded ~path:C.notify_path key);
    Ipc.serve ~path:C.socket_path dispatch_handler;
    Sq.drain ()
end
