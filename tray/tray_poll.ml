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
    try (Unix.stat paths.Runtime.config_path).Unix.st_mtime with Unix.Unix_error _ -> 0.
  in
  match !cached with
    | Some (seen, ds) when seen = stamp -> ds
    | _ ->
        let ds = try load_domains () with Failure msg ->
          Log.warn "tray: %s: %s" paths.Runtime.config_path msg;
          []
        in
        cached := Some (stamp, ds);
        ds

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let int_field json name =
  match member name json with
    | Some (`Int n) -> Some n
    | _ -> None

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
  match member name json with
    | Some (`Bool b) -> Some b
    | _ -> None

let string_field json name =
  match member name json with
    | Some (`String s) when s <> "" -> Some s
    | _ -> None

let uploads_of json =
  match member "uploading" json with
    | Some (`List items) ->
        List.filter_map
          (fun item ->
            match (string_field item "name", string_field item "rel") with
              | Some name, Some rel -> Some { Tray_model.name; rel }
              | _ -> None)
          items
    | _ -> []

let status_of_json (d : domain) json =
  match bool_field json "ok" with
    | Some false | None -> Tray_model.unreachable d.name
    | Some true ->
        {
          Tray_model.name = d.name;
          uploads = Some (Option.value (int_field json "pendingUploads") ~default:0);
          downloads = Some (Option.value (int_field json "pendingDownloads") ~default:0);
          paused = Some (Option.value (bool_field json "paused") ~default:false);
          uploading = uploads_of json;
          pending_bytes = int64_field json "pendingBytes";
          bytes_uploaded = int64_field json "bytesUploaded";
          upload_rate = float_field json "uploadBytesPerSec";
          (* The daemon reports where it actually mounted; the config only says
             where it was asked to. Prefer the fact over the intention, and keep
             the config's answer for a domain that is not answering at all. *)
          mount = Some (Option.value (string_field json "mount") ~default:d.mount);
        }

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
          Ipc.send_lwt ~timeout:1.5 ~socket_path:d.socket {|{"action":"status"}|}
        in
        status_of_json d (Yojson.Basic.from_string reply))
      (fun _ -> Lwt.return (Tray_model.unreachable d.name))
  in
  try Lwt_main.run (Lwt_list.map_p ask ds)
  with e ->
    Log.warn "tray: poll failed: %s" (Printexc.to_string e);
    List.map (fun d -> Tray_model.unreachable d.name) ds

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
        try Unix.execvp "xdg-open" [|"xdg-open"; path|]
        with _ -> exit 127)
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
