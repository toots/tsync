type domain = { name : string; socket : string; mount : string }

let paths = Runtime.default_paths ()

(* Re-read on mtime rather than once at startup: `tsync configure' adding a
   domain should show up in the menu, and rather than on every poll because the
   answer changes about once a year. *)
let cached : (float * domain list) option ref = ref None

let load_domains () =
  let config = Conf_parsing.load paths.Runtime.config_path in
  List.map
    (fun (d : Conf_parsing.domain) ->
      {
        name = d.Conf_parsing.name;
        socket = Runtime.domain_socket_path paths d.Conf_parsing.name;
        mount = Conf_parsing.mount_point_of d;
      })
    config.Conf_parsing.domains

let domains () =
  let stamp =
    try (Unix.stat paths.Runtime.config_path).Unix.st_mtime
    with Unix.Unix_error _ -> 0.
  in
  match !cached with
    | Some (seen, ds) when seen = stamp -> ds
    | _ ->
        let ds =
          try load_domains ()
          with Failure msg ->
            Log.warn "tray: %s: %s" paths.Runtime.config_path msg;
            []
        in
        cached := Some (stamp, ds);
        ds

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let int_field json name =
  match member name json with Some (`Int n) -> Some n | _ -> None

let int64_field json name =
  match member name json with
    | Some (`Int n) -> Some (Int64.of_int n)
    | _ -> None

let float_field json name =
  match member name json with
    | Some (`Float f) -> Some f
    | Some (`Int n) -> Some (float_of_int n)
    | _ -> None

let bool_field json name =
  match member name json with Some (`Bool b) -> Some b | _ -> None

let string_field json name =
  match member name json with
    | Some (`String s) when s <> "" -> Some s
    | _ -> None

(* [Ipc.send], the blocking one, has no timeout, and this loop is single
   threaded: one wedged daemon would freeze the whole tray. Every domain goes at
   once and each is bounded, so a poll costs the timeout at worst however many
   domains there are. *)
let poll ds =
  let ask d =
    Lwt.catch
      (fun () ->
        let open Lwt.Syntax in
        let+ reply =
          Ipc.send_lwt ~timeout:1.5 ~socket_path:d.socket
            {|{"action":"status"}|}
        in
        Menu.of_status_json ~name:d.name (Yojson.Safe.from_string reply))
      (fun _ -> Lwt.return (Menu.unreachable d.name))
  in
  try Lwt_main.run (Lwt_list.map_p ask ds)
  with e ->
    Log.warn "tray: poll failed: %s" (Printexc.to_string e);
    List.map (fun d -> Menu.unreachable d.name) ds

let list_field json name =
  match member name json with Some (`List items) -> items | _ -> []

(* Reads a field out of a sub-object that may not be there at all, which is
   every one of these: the daemon leaves out what its frontend does not keep. *)
let sub json name field key =
  Option.bind (member name json) (fun o -> field o key)

let backend_of json =
  {
    Menu.backend_name =
      Option.value (string_field json "name") ~default:"backend";
    role = Option.value (string_field json "role") ~default:"?";
    backend_reachable =
      Option.value (bool_field json "reachable") ~default:false;
    latency_ms = float_field json "latencyMs";
    backend_error = string_field json "error";
    journal_entries = sub json "journal" int_field "entries";
    journal_behind = sub json "journal" int_field "behind";
  }

(* The frontends of one domain, which on Linux is one. Their queue and byte
   counters are summed rather than picked from the first: two frontends serving
   a domain are each doing part of its work. *)
let frontend_sum json key field =
  match
    List.filter_map (fun f -> field f key) (list_field json "frontends")
  with
    | [] -> None
    | values -> Some (List.fold_left ( + ) 0 values)

let frontend_sum64 json key =
  match
    List.filter_map (fun f -> int64_field f key) (list_field json "frontends")
  with
    | [] -> None
    | values -> Some (List.fold_left Int64.add 0L values)

let frontend_first json key =
  List.find_map (fun f -> string_field f key) (list_field json "frontends")

let domain_stats_of json =
  {
    Menu.domain_name = Option.value (string_field json "name") ~default:"domain";
    mount_point = frontend_first json "mountPoint";
    read_only = Option.value (bool_field json "domainReadOnly") ~default:false;
    versioning = Option.value (bool_field json "versioning") ~default:false;
    cache_chunks = sub json "cache" int_field "chunks";
    cache_bytes = sub json "cache" int64_field "bytes";
    cache_max = sub json "cache" int64_field "maxCache";
    in_uploads = frontend_sum json "pendingUploads" int_field;
    in_downloads = frontend_sum json "pendingDownloads" int_field;
    staged = frontend_sum json "stagedFiles" int_field;
    bytes_read = frontend_sum64 json "bytesRead";
    bytes_written = frontend_sum64 json "bytesWritten";
    wal_pending = sub json "wal" int_field "pending";
    wal_stuck = sub json "wal" int_field "stuck";
    backends = List.map backend_of (list_field json "backends");
  }

let stats_of_json json =
  match bool_field json "ok" with
    | Some false | None -> None
    | Some true ->
        let server = member "server" json in
        let process = member "process" json in
        let traffic = member "traffic" json in
        let field o name f = Option.bind o (fun o -> f o name) in
        Some
          {
            Menu.host =
              Option.value (field server "hostname" string_field) ~default:"?";
            frontend =
              Option.value (field server "frontend" string_field) ~default:"?";
            pid = Option.value (field server "pid" int_field) ~default:0;
            uptime =
              Option.value
                (field server "uptimeSeconds" float_field)
                ~default:0.;
            cpu_percent =
              Option.value
                (field process "cpuPercentAvg" float_field)
                ~default:0.;
            rss =
              Option.value (field process "rssBytes" int64_field) ~default:0L;
            heap =
              Option.value (field process "heapBytes" int64_field) ~default:0L;
            uploaded =
              Option.value
                (field traffic "bytesUploaded" int64_field)
                ~default:0L;
            up_rate =
              Option.value
                (field traffic "uploadBytesPerSec" float_field)
                ~default:0.;
            downloaded =
              Option.value
                (field traffic "bytesDownloaded" int64_field)
                ~default:0L;
            down_rate =
              Option.value
                (field traffic "downloadBytesPerSec" float_field)
                ~default:0.;
            domain_stats = List.map domain_stats_of (list_field json "domains");
          }

(* Longer than the status poll's timeout because it is doing more: the daemon
   reaches every backend before answering. Still bounded, and still one request
   per domain at once, since this runs in the same single-threaded loop. *)
let stats_timeout = 4.

let stats ds =
  let ask d =
    Lwt.catch
      (fun () ->
        let open Lwt.Syntax in
        let+ reply =
          Ipc.send_lwt ~timeout:stats_timeout ~socket_path:d.socket
            (Printf.sprintf {|{"action":"stats","domain":%s}|}
               (Yojson.Safe.to_string (`String d.name)))
        in
        stats_of_json (Yojson.Safe.from_string reply))
      (fun e ->
        Log.debug "tray: stats %S: %s" d.name (Printexc.to_string e);
        Lwt.return None)
  in
  try List.filter_map Fun.id (Lwt_main.run (Lwt_list.map_p ask ds))
  with e ->
    Log.warn "tray: stats failed: %s" (Printexc.to_string e);
    []

let set_paused ds paused =
  let arg = if paused then "on" else "off" in
  let ask d =
    Lwt.catch
      (fun () ->
        let open Lwt.Syntax in
        let+ _ =
          Ipc.send_lwt ~timeout:1.5 ~socket_path:d.socket
            (Printf.sprintf {|{"action":"pause","arg":"%s"}|} arg)
        in
        ())
      (fun e ->
        Log.warn "tray: pause %S: %s" d.name (Printexc.to_string e);
        Lwt.return_unit)
  in
  try Lwt_main.run (Lwt_list.iter_p ask ds)
  with e -> Log.warn "tray: pause failed: %s" (Printexc.to_string e)

(* The daemon reports where it actually mounted; the config only says where it
   was asked to. A domain that is not answering keeps the config's answer, which
   is still where its folder would be. *)
let mount_of ds name =
  match List.find_opt (fun d -> d.name = name) ds with
    | Some d -> Some d.mount
    | None -> None

let file_manager = "org.freedesktop.FileManager1"
let file_manager_path = "/org/freedesktop/FileManager1"

(* file:// wants an absolute path with everything outside the unreserved set
   escaped, and the separators left alone. No encoder in the tree fits: the one
   in Deferred is private and escapes a different alphabet. *)
let file_uri path =
  let buf = Buffer.create (String.length path + 16) in
  Buffer.add_string buf "file://";
  String.iter
    (fun c ->
      match c with
        | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' | '/' ->
            Buffer.add_char buf c
        | c -> Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c)))
    path;
  Buffer.contents buf

(* xdg-open cannot select a file, so the fallback opens the containing folder
   either way. SIGCHLD is ignored once in [Tray], so this is reaped for us. *)
let xdg_open path =
  match Unix.fork () with
    | 0 -> (
        try Unix.execvp "xdg-open" [| "xdg-open"; path |] with _ -> exit 127)
    | _ -> ()
    | exception Unix.Unix_error (e, _, _) ->
        Log.warn "tray: cannot start xdg-open: %s" (Unix.error_message e)

let show conn member ~fallback path =
  try
    ignore
      (Dbus.call conn ~timeout:5000 ~dest:file_manager ~path:file_manager_path
         ~iface:file_manager ~member
         [Dbus.Array ("s", [Dbus.String (file_uri path)]); Dbus.String ""])
  with Dbus.Error (name, msg) ->
    Log.debug "tray: %s: %s: %s" member name msg;
    xdg_open fallback

let open_folder conn path = show conn "ShowFolders" ~fallback:path path

let reveal_file conn path =
  show conn "ShowItems" ~fallback:(Filename.dirname path) path
