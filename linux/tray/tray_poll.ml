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
        Menu.of_stats_json (Yojson.Safe.from_string reply))
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
