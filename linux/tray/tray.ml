let item_path = "/StatusNotifierItem"
let menu_path = "/MenuBar"

(* What the macOS menu polls at, for the same reason: the daemon publishes
   events for content changes, not for queue depth. *)
let poll_every = 3.

(* Long enough that an idle tray is not a busy loop, short enough that a click
   is answered before it feels dropped. *)
let tick_ms = 250

(* libdbus falls back to X11 autolaunch when it has no address, which in an ssh
   session starts a second, private bus -- one nobody is drawing, forever. The
   standard socket is where a real session's bus is, so name it rather than let
   libdbus guess. *)
let ensure_bus_address () =
  match Sys.getenv_opt "DBUS_SESSION_BUS_ADDRESS" with
    | Some a when a <> "" -> ()
    | _ -> (
        match Sys.getenv_opt "XDG_RUNTIME_DIR" with
          | Some dir when Sys.file_exists (Filename.concat dir "bus") ->
              Unix.putenv "DBUS_SESSION_BUS_ADDRESS"
                ("unix:path=" ^ Filename.concat dir "bus")
          | _ ->
              failwith
                "no session bus: the tray needs a running desktop session")

let run () =
  ensure_bus_address ();
  (* The tray forks only to run xdg-open, and never waits on one: the POSIX
     auto-reap is exactly what is wanted and beats a double fork. *)
  Sys.set_signal Sys.sigchld Sys.Signal_ignore;
  let conn =
    try Dbus.session_bus ()
    with Dbus.Error (_, msg) -> failwith ("no session bus: " ^ msg)
  in
  (* Two trays would draw two icons and fight over one daemon's pause switch.
     DO_NOT_QUEUE so the second finds out now rather than inheriting the name
     whenever the first happens to exit. *)
  if not (Dbus.request_name_exclusive conn "org.tsync.Tray") then (
    print_endline "tsync-tray is already running";
    exit 0);
  if not (Dbus.request_name_exclusive conn (Sni.bus_name ())) then
    failwith ("cannot claim " ^ Sni.bus_name ());

  let sni = Sni.create conn ~item_path ~menu_path in
  let menu = Dbusmenu.create conn ~path:menu_path in
  if not (Sni.host_registered sni) then
    Log.warn
      "tray: no StatusNotifier host is running, so nothing will draw the icon; \
       on GNOME this needs the AppIndicator extension";

  let quit = ref false in
  let domains = ref (Tray_poll.domains ()) in
  let last_poll = ref neg_infinity in

  let refresh () =
    domains := Tray_poll.domains ();
    let rendered = Tray_model.render (Tray_poll.poll !domains) in
    Sni.set sni ~icon:rendered.Tray_model.icon
      ~tooltip:rendered.Tray_model.tooltip;
    Dbusmenu.set menu rendered.Tray_model.entries;
    last_poll := Unix.gettimeofday ()
  in

  Dbusmenu.on_click menu (fun action ->
      match action with
        | Tray_model.Nothing -> ()
        | Quit -> quit := true
        | Open_folder path -> Tray_poll.open_folder conn path
        | Reveal_file path -> Tray_poll.reveal_file conn path
        | Set_paused paused ->
            Tray_poll.set_paused !domains paused;
            (* Read it back rather than assume: the checkmark should show what
               the daemon did, not what it was asked to do. *)
            refresh ());

  refresh ();

  let rec loop () =
    if !quit then Log.info "tray: quit"
    else if not (Dbus.read_write conn tick_ms) then
      (* The bus going away means the session is ending. Nothing to report. *)
      Log.info "tray: session bus closed"
    else (
      drain ();
      if (not !quit) && Unix.gettimeofday () -. !last_poll >= poll_every then
        refresh ();
      loop ())
  and drain () =
    match Dbus.pop_message conn with
      | None -> ()
      | Some msg ->
          handle msg;
          drain ()
  and handle msg =
    if not (Sni.handle sni msg || Dbusmenu.handle menu msg) then
      (* Nothing claimed it. A signal is free to go unread, but a call left
         unanswered costs the caller its full timeout -- 25 seconds of a menu
         looking wedged -- so every one of them gets an error. *)
      if
        Dbus.message_type msg = Dbus.method_call
        && not (Dbus.message_no_reply msg)
      then (
        Log.debug "tray: unhandled %s %s.%s" (Dbus.message_path msg)
          (Dbus.message_interface msg)
          (Dbus.message_member msg);
        Dbus.error_reply conn msg "org.freedesktop.DBus.Error.UnknownMethod"
          "tsync-tray does not implement that")
  in
  loop ();
  Dbus.close conn
