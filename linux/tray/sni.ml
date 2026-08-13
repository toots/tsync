let watcher = "org.kde.StatusNotifierWatcher"
let watcher_path = "/StatusNotifierWatcher"

(* Hosts disagree about which name an item's interface has: KDE minted the
   protocol under org.kde and the freedesktop spelling followed. Nothing else
   uses these member names, so answering to both costs nothing. *)
let ifaces =
  ["org.kde.StatusNotifierItem"; "org.freedesktop.StatusNotifierItem"]

let properties = "org.freedesktop.DBus.Properties"
let introspectable = "org.freedesktop.DBus.Introspectable"
let peer = "org.freedesktop.DBus.Peer"

(* One item per process, and the watcher keys its list on this. *)
let bus_name () =
  Printf.sprintf "org.kde.StatusNotifierItem-%d-1" (Unix.getpid ())

type t = {
  conn : Dbus.connection;
  item_path : string;
  menu_path : string;
  mutable icon : string;
  mutable tooltip : string;
  mutable host : bool;
}

let host_registered t = t.host

let props t =
  [
    ("Category", Dbus.String "ApplicationStatus");
    ("Id", Dbus.String "tsync");
    ("Title", Dbus.String "tsync");
    (* Never NeedsAttention: the glyph already says what is wrong, and KDE
       animates attention, which for a sync tool would blink all day. *)
    ("Status", Dbus.String "Active");
    ("WindowId", Dbus.Int32 0l);
    ("IconName", Dbus.String t.icon);
    (* Empty rather than absent, so a host that reads the pixmap
       unconditionally gets an answer instead of an error. *)
    ("IconPixmap", Dbus.Array ("(iiay)", []));
    ("OverlayIconName", Dbus.String "");
    ("AttentionIconName", Dbus.String "");
    ("AttentionMovieName", Dbus.String "");
    ( "ToolTip",
      Dbus.Struct
        [
          Dbus.String "";
          Dbus.Array ("(iiay)", []);
          Dbus.String t.tooltip;
          Dbus.String "";
        ] );
    (* The whole item is a menu: a left click should drop it down rather than
       activate something, there being no window to raise. *)
    ("ItemIsMenu", Dbus.Bool true);
    ("Menu", Dbus.Path t.menu_path);
  ]

let introspection =
  Dbus.introspection
    {xml|  <interface name="org.kde.StatusNotifierItem">
    <property name="Category" type="s" access="read"/>
    <property name="Id" type="s" access="read"/>
    <property name="Title" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="WindowId" type="i" access="read"/>
    <property name="IconName" type="s" access="read"/>
    <property name="IconPixmap" type="a(iiay)" access="read"/>
    <property name="OverlayIconName" type="s" access="read"/>
    <property name="AttentionIconName" type="s" access="read"/>
    <property name="AttentionMovieName" type="s" access="read"/>
    <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    <property name="ItemIsMenu" type="b" access="read"/>
    <property name="Menu" type="o" access="read"/>
    <method name="Activate">
      <arg name="x" type="i" direction="in"/>
      <arg name="y" type="i" direction="in"/>
    </method>
    <method name="SecondaryActivate">
      <arg name="x" type="i" direction="in"/>
      <arg name="y" type="i" direction="in"/>
    </method>
    <method name="ContextMenu">
      <arg name="x" type="i" direction="in"/>
      <arg name="y" type="i" direction="in"/>
    </method>
    <method name="Scroll">
      <arg name="delta" type="i" direction="in"/>
      <arg name="orientation" type="s" direction="in"/>
    </method>
    <signal name="NewIcon"/>
    <signal name="NewToolTip"/>
    <signal name="NewStatus"><arg name="status" type="s"/></signal>
  </interface>
|xml}

let announce t member =
  List.iter
    (fun iface -> Dbus.emit t.conn ~path:t.item_path ~iface ~member [])
    ifaces

(* Asking the watcher to take us. [ServiceUnknown] is the ordinary case at
   login, when the panel has not started yet -- the NameOwnerChanged match in
   [create] is what picks it up later. *)
let register t =
  (try
     ignore
       (Dbus.call t.conn ~dest:watcher ~path:watcher_path ~iface:watcher
          ~member:"RegisterStatusNotifierItem"
          [Dbus.String (bus_name ())])
   with Dbus.Error (name, msg) -> Log.debug "tray: register: %s: %s" name msg);
  t.host <-
    (try
       match
         Dbus.call t.conn ~dest:watcher ~path:watcher_path ~iface:properties
           ~member:"Get"
           [Dbus.String watcher; Dbus.String "IsStatusNotifierHostRegistered"]
       with
         | [Dbus.Variant (Dbus.Bool b)] -> b
         | _ -> false
     with Dbus.Error _ -> false)

let create conn ~item_path ~menu_path =
  let t =
    {
      conn;
      item_path;
      menu_path;
      icon = "view-refresh";
      tooltip = "tsync";
      host = false;
    }
  in
  (* The panel restarting takes the item's registration with it. Watching the
     watcher's owner is what brings the icon back, and its absence is the
     classic "it disappeared after a Plasma restart". *)
  Dbus.add_match conn
    (Printf.sprintf
       "type='signal',sender='org.freedesktop.DBus',path='/org/freedesktop/DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='%s'"
       watcher);
  register t;
  t

let set t ~icon ~tooltip =
  (* Only on change: a host re-reads every property on each of these, and this
     is called every poll. *)
  if icon <> t.icon then (
    t.icon <- icon;
    announce t "NewIcon");
  if tooltip <> t.tooltip then (
    t.tooltip <- tooltip;
    announce t "NewToolTip")

let handle_properties t msg =
  match (Dbus.message_member msg, Dbus.body msg) with
    | "Get", [Dbus.String iface; Dbus.String name] when List.mem iface ifaces
      -> (
        match List.assoc_opt name (props t) with
          | Some v -> Dbus.reply t.conn msg [Dbus.Variant v]
          | None -> Dbus.unknown_property t.conn msg name)
    | "GetAll", [Dbus.String iface] when List.mem iface ifaces ->
        Dbus.reply t.conn msg [Dbus.dict_sv (props t)]
    (* An interface we do not have is not an error for GetAll: the caller asked
       what is there, and the answer is nothing. *)
    | "GetAll", [Dbus.String _] -> Dbus.reply t.conn msg [Dbus.dict_sv []]
    | "Set", _ -> Dbus.read_only_property t.conn msg
    | _ -> Dbus.unknown_method t.conn msg

(* The watcher's owner changing to something means the panel is back and has
   forgotten us. Re-register, then re-announce: without that the icon returns
   holding whatever it said at login. *)
let handle_name_owner_changed t msg =
  match Dbus.body msg with
    | [Dbus.String name; _; Dbus.String owner]
      when name = watcher && owner <> "" ->
        Log.info "tray: %s is back, registering again" watcher;
        register t;
        announce t "NewIcon";
        announce t "NewToolTip"
    | _ -> ()

let handle t msg =
  if
    Dbus.message_type msg = Dbus.signal
    && Dbus.message_interface msg = "org.freedesktop.DBus"
    && Dbus.message_member msg = "NameOwnerChanged"
  then (
    handle_name_owner_changed t msg;
    true)
  else if Dbus.message_path msg <> t.item_path then false
  else (
    let requested = Dbus.message_interface msg in
    if requested = properties then handle_properties t msg
    else if requested = introspectable then
      Dbus.reply t.conn msg [Dbus.String introspection]
    else if requested = peer then Dbus.reply t.conn msg []
    else if List.mem requested ifaces then (
      match Dbus.message_member msg with
        (* Nothing to do for any of them -- ItemIsMenu says the click belongs to
           the menu -- but each still has to be answered, or the host waits out
           its timeout on a click nobody meant anything by. *)
        | "Activate" | "SecondaryActivate" | "ContextMenu" | "Scroll" ->
            Dbus.reply t.conn msg []
        | _ -> Dbus.unknown_method t.conn msg)
    else Dbus.unknown_interface t.conn msg;
    true)
