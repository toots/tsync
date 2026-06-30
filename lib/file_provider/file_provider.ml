type context = {
  store : File_store.t;
  files : File.store;
  domain_name : string;
  domain_prefix : string;
  mount_point : string;
  socket_path : string;
  notify_path : string;
}

let auto_evict = ref true
let set_pending_version _ek = ()

let make_context ~store ~files ~domain_name ~domain_prefix ~mount_point =
  { store; files; domain_name; domain_prefix; mount_point;
    socket_path = File_store.socket_path store;
    notify_path = File_store.notify_path store }

let path_to_key ctx path =
  let rel =
    if path = "/" then ""
    else if path.[0] = '/' then String.sub path 1 (String.length path - 1)
    else path
  in
  ctx.domain_prefix ^ rel

let file ctx key = File.make ~store:ctx.files ~key

(* ── JSON helpers ─────────────────────────────────────────────────────────── *)

let ok_json fields =
  Yojson.Safe.to_string (`Assoc (("ok", `Bool true) :: fields))

let error_json msg =
  Yojson.Safe.to_string (`Assoc [("ok", `Bool false); ("error", `String msg)])

let get_str obj key =
  match List.assoc_opt key obj with
  | Some (`String s) -> s
  | _ -> ""

let file_etag f =
  match File.read_manifest f with
  | Some (`Clean m) -> m.Manifest.h1
  | _ -> ""

(* ── JSON handlers ────────────────────────────────────────────────────────── *)

let handle_stat ctx key =
  let f = file ctx key in
  match File.stat f with
  | Some st ->
    let is_dirty = match File.read_manifest f with
      | Some `Dirty -> true
      | _ -> false
    in
    ok_json [
      "size", `Int (Int64.to_int st.Unix.LargeFile.st_size);
      "mtime", `Float st.Unix.LargeFile.st_mtime;
      "etag", `String (file_etag f);
      "isUploaded", `Bool (not is_dirty);
    ]
  | None ->
    match File_store.head_opt ctx.store ~key with
    | None -> error_json "not found"
    | Some (e : S3_client.file_entry) ->
      ok_json [
        "size", `Int e.size;
        "mtime", `Float e.last_modified;
        "etag", `Null;
        "isUploaded", `Bool true;
      ]

let file_entry_json (e : S3_client.file_entry) =
  `Assoc [
    "key", `String e.key;
    "size", `Int e.size;
    "mtime", `Float e.last_modified;
  ]

let handle_list_dir ctx prefix =
  let files, dirs = File_store.list_directory ctx.store ~prefix in
  ok_json [
    "dirs", `List (List.map (fun d -> `String d) dirs);
    "files", `List (List.map file_entry_json files);
  ]

let handle_list_all ctx prefix =
  let files = File_store.list_all_files ctx.store ~prefix in
  ok_json ["files", `List (List.map file_entry_json files)]

let handle_ensure_cached ctx key =
  let f = file ctx key in
  File.ensure_cached f;
  ok_json ["localPath", `String (File.local_path f)]

let handle_create ctx key =
  File.create (file ctx key);
  ok_json []

let handle_write ctx key staging_path =
  let f = file ctx key in
  ignore (File.cancel_upload f);
  File.ensure_parent_dir f;
  Unix.rename staging_path (File.local_path f);
  File.mark_dirty f;
  File.queue_put f;
  match (try Some (Unix.LargeFile.stat (File.local_path f)) with _ -> None) with
  | Some st ->
    ok_json [
      "size", `Int (Int64.to_int st.Unix.LargeFile.st_size);
      "mtime", `Float st.Unix.LargeFile.st_mtime;
    ]
  | None -> ok_json []

let handle_evict ctx key =
  File.evict (file ctx key);
  ok_json []

let handle_delete ctx key =
  File.delete (file ctx key);
  ok_json []

let handle_rename ctx src_key dst_key =
  File.rename ~src:(file ctx src_key) ~dst:(file ctx dst_key);
  ok_json []

let handle_mkdir ctx key =
  File.mkdir (file ctx key);
  ok_json []

let handle_rmdir ctx key =
  File.rmdir (file ctx key);
  ok_json []

let json_handler ctx line =
  match Yojson.Safe.from_string line with
  | exception _ -> error_json "invalid JSON"
  | `Assoc obj ->
    let action = get_str obj "action" in
    let path = get_str obj "path" in
    (try
       match action with
       | "stat" -> handle_stat ctx path
       | "list_dir" -> handle_list_dir ctx path
       | "list_all" -> handle_list_all ctx path
       | "ensure_cached" -> handle_ensure_cached ctx path
       | "create" -> handle_create ctx path
       | "write" -> handle_write ctx path (get_str obj "staging")
       | "evict" -> handle_evict ctx path
       | "delete" -> handle_delete ctx path
       | "rename" -> handle_rename ctx (get_str obj "src") path
       | "mkdir" -> handle_mkdir ctx path
       | "rmdir" -> handle_rmdir ctx path
       | _ -> error_json ("unknown action: " ^ action)
     with exn -> error_json (Printexc.to_string exn))
  | _ -> error_json "expected JSON object"

(* ── CLI IPC handler (same text protocol as Linux) ──────────────────────── *)

let cli_handler ctx line =
  match Ipc.parse_command line with
    | Stop -> "STOP"
    | Status ->
        Printf.sprintf {|STATUS {"domain":"%s","running":true}|}
          ctx.domain_name
    | Evict arg ->
        let key = path_to_key ctx arg in
        File.evict (File.make ~store:ctx.files ~key);
        Ipc.notify_evict ~path:ctx.notify_path key;
        "OK"
    | Restore arg ->
        let key = path_to_key ctx arg in
        (try
           File.ensure_cached (File.make ~store:ctx.files ~key);
           "OK"
         with exn ->
           "ERROR " ^ Printexc.to_string exn)
    | Auto_evict arg -> (
        match arg with
          | "on" ->
              auto_evict := true;
              "OK"
          | "off" ->
              auto_evict := false;
              "OK"
          | _ -> if !auto_evict then "on" else "off")
    | Full_resync ->
        (* ponytail: signal FileProvider extension to re-enumerate *)
        "OK"
    | exception Failure msg -> msg

(* ── Unified dispatch + main entry point ────────────────────────────────── *)

let dispatch_handler ctx line =
  if String.length line > 0 && line.[0] = '{' then
    json_handler ctx line
  else
    cli_handler ctx line

let mount ctx _argv = Ipc.serve ~path:ctx.socket_path (dispatch_handler ctx)
