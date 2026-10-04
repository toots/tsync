open Tsync_core
open Tsync_config
open Tsync_ipc
open Tsync_owner
open Tsync_dbus
open Tsync_menu
module M = Menu_model

(* §10. *)
let poll_interval = 3.
let status_deadline = 1.5
let stats_deadline = 4.
let pause_deadline = 5.
let stats_debounce = 1.
let file_manager_timeout = 5.
let watcher_timeout = 5.
let item_path = "/StatusNotifierItem"
let menu_path = "/MenuBar"

let item_interfaces =
  ["org.kde.StatusNotifierItem"; "org.freedesktop.StatusNotifierItem"]

let menu_interface = "com.canonical.dbusmenu"
let watcher = "org.kde.StatusNotifierWatcher"
let watcher_path = "/StatusNotifierWatcher"
let properties_interface = "org.freedesktop.DBus.Properties"
let error name = "org.freedesktop.DBus.Error." ^ name

type domain = { name : string; socket : string; configured : string option }

(* [lock] guards every mutable field and the layout; it is never held across
   a wait. *)
type t = {
  bus : Bus.t;
  item_name : string;
  lock : Mutex.t;
  layout : Layout.t;
  mutable icon : string;
  mutable tooltip : string;
  mutable domains : domain list;
  mutable reported_mounts : (string * string) list;
  mutable stats_started : float;
  refreshing : Rt.Fmutex.t;
  finished : int Rt.Promise.t;
}

let locked t f = Mutex.protect t.lock f

let emit t ~path ~interface ~member values =
  Bus.send t.bus (Dbus.signal ~path ~interface ~member values)

(* Called with the lock held, so that announcements leave in the order of the
   changes they announce. *)
let announce t parents =
  List.iter
    (fun parent ->
      emit t ~path:menu_path ~interface:menu_interface ~member:"LayoutUpdated"
        [Uint32 (Layout.revision t.layout); Int32 parent])
    parents

let change_layout t f =
  locked t (fun () ->
      let parents = f t.layout in
      announce t parents;
      parents <> [])

let item_signal t member =
  List.iter
    (fun interface -> emit t ~path:item_path ~interface ~member [])
    item_interfaces

let label ~indent text =
  String.make (4 * indent) ' '
  ^ String.concat "__" (String.split_on_char '_' text)

let row_properties : M.entry -> (string * Dbus.value) list = function
  | Separator -> [("type", String "separator")]
  | Item i ->
      [
        ("label", Dbus.String (label ~indent:i.indent i.label));
        ("enabled", Bool i.enabled);
        ("visible", Bool true);
      ]
      @ (match i.icon with
        | Some n -> [("icon-name", Dbus.String n)]
        | None -> [])
      @ (match i.checked with
        | Some c ->
            [
              ("toggle-type", Dbus.String "checkmark");
              ("toggle-state", Int32 (if c then 1 else 0));
            ]
        | None -> [])
      @ if i.submenu then [("children-display", Dbus.String "submenu")] else []

let root_properties = [("children-display", Dbus.String "submenu")]

let dictionary ?(names = []) properties =
  Dbus.Array
    ( "{sv}",
      List.filter_map
        (fun (name, v) ->
          if names = [] || List.mem name names then
            Some (Dbus.Dict_entry (String name, Variant v))
          else None)
        properties )

let rec node ~depth ~names id properties (children : Layout.row list) =
  Dbus.Struct
    [
      Int32 id;
      dictionary ~names properties;
      Array
        ( "v",
          if depth = 0 then []
          else
            List.map
              (fun (r : Layout.row) ->
                Dbus.Variant
                  (node ~depth:(depth - 1) ~names r.id (row_properties r.entry)
                     r.children))
              children );
    ]

let uri path =
  let b = Buffer.create (String.length path + 8) in
  Buffer.add_string b "file://";
  String.iter
    (fun c ->
      match c with
        | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' | '/' ->
            Buffer.add_char b c
        | c -> Printf.bprintf b "%%%02X" (Char.code c))
    path;
  Buffer.contents b

(* §7. The helper is reaped by a fiber of its own, so it is never a zombie. *)
let show t ~folder path =
  match
    Bus.call t.bus ~timeout:file_manager_timeout
      ~destination:"org.freedesktop.FileManager1"
      ~path:"/org/freedesktop/FileManager1"
      ~interface:"org.freedesktop.FileManager1"
      ~member:(if folder then "ShowFolders" else "ShowItems")
      [Array ("s", [String (uri path)]); String ""]
  with
    | Ok _ -> ()
    | Error reason -> (
        Log.debug "tray: no file manager service (%s), using xdg-open" reason;
        let target = if folder then path else Filename.dirname path in
        match
          Unix.create_process "xdg-open" [| "xdg-open"; target |] Unix.stdin
            Unix.stdout Unix.stderr
        with
          | pid -> ignore (Unix.waitpid [] pid)
          | exception Unix.Unix_error (e, _, _) ->
              Log.warn "tray: cannot run xdg-open: %s" (Unix.error_message e))

let mount_point t name =
  locked t (fun () ->
      match List.assoc_opt name t.reported_mounts with
        | Some m -> Some m
        | None ->
            Option.bind
              (List.find_opt (fun d -> d.name = name) t.domains)
              (fun d -> d.configured))

(* One request to every domain's owner at the same time, in the owner's own
   encoding. *)
let ask_all t ~deadline request =
  let domains = locked t (fun () -> t.domains) in
  let request = Protocol.encode request in
  List.combine domains
    (Rt.map_concurrently (fun d -> Ipc.ask ~deadline d.socket request) domains)

(* A config that cannot be used is no domains, whatever the reason (§5.2). *)
let configured_domains () =
  let none reason =
    Log.once ("tray-config:" ^ reason) Log.Warn "tray: no domains: %s" reason;
    []
  in
  match Paths.read_config ~interactive:false () with
    | None -> none ("no config at " ^ Paths.config_file ())
    | Some text -> (
        match Config.of_string text with
          | config ->
              List.map
                (fun (d : Config.domain) ->
                  {
                    name = Domain_name.to_string d.name;
                    socket = Paths.owner_socket d.name;
                    configured = Mounts.configured d;
                  })
                config.domains
          | exception Config.Invalid reason -> none reason)
    | exception e -> none (Fail.classify e).reason

let string_field name = function
  | `Assoc l -> (
      match List.assoc_opt name l with Some (`String s) -> Some s | _ -> None)
  | _ -> None

let refresh t =
  Rt.Fmutex.with_lock t.refreshing @@ fun () ->
  let domains = try configured_domains () with _ -> [] in
  let replies =
    Rt.map_concurrently
      (fun d ->
        Ipc.ask ~deadline:status_deadline d.socket (Protocol.encode Status))
      domains
  in
  let answers =
    List.map2
      (fun d reply -> (d, reply, Option.bind reply M.status_of_json))
      domains replies
  in
  let menu =
    M.render ~quit:"Quit tsync tray"
      (List.map (fun (d, _, status) -> (d.name, status)) answers)
  in
  locked t (fun () ->
      t.domains <- domains;
      t.reported_mounts <-
        List.filter_map
          (fun (d, reply, status) ->
            match (status, Option.bind reply (string_field "mount")) with
              | Some _, Some mount -> Some (d.name, mount)
              | _ -> None)
          answers;
      if menu.icon <> t.icon then (
        t.icon <- menu.icon;
        item_signal t "NewIcon");
      if menu.tooltip <> t.tooltip then (
        t.tooltip <- menu.tooltip;
        item_signal t "NewToolTip");
      announce t (Layout.set_menu t.layout ~now:(Rt.now ()) menu.entries))

let fetch_stats t =
  let due =
    locked t (fun () ->
        let now = Rt.now () in
        if now -. t.stats_started < stats_debounce then false
        else (
          t.stats_started <- now;
          true))
  in
  if due then
    Rt.spawn ~name:"tray stats" (fun () ->
        let rows =
          M.stats
            (List.filter_map
               (fun (_, reply) -> Option.bind reply M.stats_of_json)
               (ask_all t ~deadline:stats_deadline (Stats [])))
        in
        ignore (change_layout t (fun layout -> Layout.set_stats layout rows)))

let set_paused t paused =
  List.iter
    (fun (d, reply) ->
      let refused why =
        Log.warn "tray: %s did not %s: %s" d.name
          (if paused then "hold" else "resume")
          why
      in
      match Option.map Protocol.failure_of_reply reply with
        | None -> refused "no answer"
        | Some None -> ()
        | Some (Some failure) -> refused failure.reason)
    (ask_all t ~deadline:pause_deadline (Pause paused));
  refresh t

let run_action t : M.action -> unit = function
  | Nothing | Show_stats -> ()
  | Quit -> ignore (Rt.Promise.try_resolve t.finished 0)
  | Set_paused paused -> set_paused t paused
  | Open_folder name -> Option.iter (show t ~folder:true) (mount_point t name)
  | Reveal { domain; rel } ->
      Option.iter
        (fun m -> show t ~folder:false (Filename.concat m rel))
        (mount_point t domain)

(* §4.4. Answers whether the layout under [id] changed, and the work to start
   once the reply is sent. *)
let opening t id =
  let changed =
    change_layout t (fun layout -> Layout.opening layout ~now:(Rt.now ()) id)
  in
  (changed, fun () -> fetch_stats t)

let click t id =
  match locked t (fun () -> Layout.find t.layout id) with
    | Some { entry = Item { enabled = true; action; _ }; _ } ->
        Rt.spawn ~name:"tray action" (fun () -> run_action t action)
    | _ -> ()

type answer =
  | Return of Dbus.value list
  | Refuse of string * string
  | Unknown_method

let invalid = Refuse (error "InvalidArgs", "unexpected arguments")
let integer = function Dbus.Int32 n | Uint32 n -> Some n | _ -> None
let text = function Dbus.String s -> Some s | _ -> None
let list_of f = function Dbus.Array (_, l) -> List.filter_map f l | _ -> []
let integers l = Dbus.Array ("i", List.map (fun n -> Dbus.Int32 n) l)

let names_no_row t id =
  id <> 0 && locked t (fun () -> Layout.find t.layout id) = None

(* Each handler answers its reply and the work to start after it is sent. *)
let event t id kind =
  match kind with
    | "opened" -> snd (opening t id)
    | "closed" ->
        ignore (change_layout t (fun layout -> Layout.closed layout id));
        ignore
    | "clicked" -> fun () -> click t id
    | _ -> ignore

let menu_call t member arguments =
  match (member, arguments) with
    | "GetLayout", [parent; depth; names] -> (
        match (integer parent, integer depth) with
          | Some parent, Some depth ->
              let names = list_of text names in
              let revision, layout =
                locked t (fun () ->
                    ( Layout.revision t.layout,
                      if parent = 0 then
                        node ~depth ~names 0 root_properties
                          (Layout.rows t.layout)
                      else (
                        match Layout.find t.layout parent with
                          | Some row ->
                              node ~depth ~names row.id
                                (row_properties row.entry) row.children
                          | None -> node ~depth ~names parent [] []) ))
              in
              (Return [Uint32 revision; layout], ignore)
          | _ -> (invalid, ignore))
    | "GetGroupProperties", [ids; names] ->
        let ids = list_of integer ids and names = list_of text names in
        let rows =
          locked t (fun () ->
              if ids = [] then Layout.all t.layout
              else List.filter_map (Layout.find t.layout) ids)
        in
        ( Return
            [
              Array
                ( "(ia{sv})",
                  List.map
                    (fun (r : Layout.row) ->
                      Dbus.Struct
                        [Int32 r.id; dictionary ~names (row_properties r.entry)])
                    rows );
            ],
          ignore )
    | "GetProperty", [id; name] -> (
        match (integer id, text name) with
          | Some id, Some name ->
              let properties =
                if id = 0 then root_properties
                else (
                  match locked t (fun () -> Layout.find t.layout id) with
                    | Some row -> row_properties row.entry
                    | None -> [])
              in
              ( Return
                  [
                    Variant
                      (Option.value ~default:(Dbus.String "")
                         (List.assoc_opt name properties));
                  ],
                ignore )
          | _ -> (invalid, ignore))
    | "AboutToShow", [id] -> (
        match integer id with
          | Some id ->
              let changed, after = opening t id in
              (Return [Bool changed], after)
          | None -> (invalid, ignore))
    | "AboutToShowGroup", [ids] ->
        let ids = list_of integer ids in
        let unknown = List.filter (names_no_row t) ids in
        let outcomes = List.map (fun id -> (id, opening t id)) ids in
        ( Return
            [
              integers
                (List.filter_map
                   (fun (id, (changed, _)) -> if changed then Some id else None)
                   outcomes);
              integers unknown;
            ],
          fun () -> List.iter (fun (_, (_, after)) -> after ()) outcomes )
    | "Event", [id; kind; _; _] -> (
        match (integer id, text kind) with
          | Some id, Some kind -> (Return [], event t id kind)
          | _ -> (invalid, ignore))
    | "EventGroup", [events] ->
        let events =
          list_of
            (function
              | Dbus.Struct [id; kind; _; _] -> (
                  match (integer id, text kind) with
                    | Some id, Some kind -> Some (id, kind)
                    | _ -> None)
              | _ -> None)
            events
        in
        let unknown = List.filter (names_no_row t) (List.map fst events) in
        let after = List.map (fun (id, kind) -> event t id kind) events in
        ( Return [integers (List.sort_uniq compare unknown)],
          fun () -> List.iter (fun f -> f ()) after )
    | ( ( "GetLayout" | "GetGroupProperties" | "GetProperty" | "AboutToShow"
        | "AboutToShowGroup" | "Event" | "EventGroup" ),
        _ ) ->
        (invalid, ignore)
    | _ -> (Unknown_method, ignore)

let item_call member =
  match member with
    | "Activate" | "SecondaryActivate" | "ContextMenu" | "Scroll" -> Return []
    | _ -> Unknown_method

let item_properties t =
  let icon, tooltip = locked t (fun () -> (t.icon, t.tooltip)) in
  let pixmaps = Dbus.Array ("(iiay)", []) in
  [
    ("Category", Dbus.String "ApplicationStatus");
    ("Id", String "tsync");
    ("Title", String "tsync");
    ("Status", String "Active");
    ("WindowId", Int32 0);
    ("IconName", String icon);
    ("IconPixmap", pixmaps);
    ("OverlayIconName", String "");
    ("AttentionIconName", String "");
    ("AttentionMovieName", String "");
    ("ToolTip", Struct [String ""; pixmaps; String tooltip; String ""]);
    ("ItemIsMenu", Bool true);
    ("Menu", Object_path menu_path);
  ]

let menu_properties =
  [
    ("Version", Dbus.Uint32 3);
    ("Status", String "normal");
    ("TextDirection", String "ltr");
    ("IconThemePath", Array ("s", []));
  ]

let standard_interfaces =
  {|<interface name="org.freedesktop.DBus.Properties">
  <method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
  <method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
  <method name="Set"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/></method>
 </interface>
 <interface name="org.freedesktop.DBus.Introspectable">
  <method name="Introspect"><arg type="s" direction="out"/></method>
 </interface>
 <interface name="org.freedesktop.DBus.Peer">
  <method name="Ping"/>
  <method name="GetMachineId"><arg type="s" direction="out"/></method>
 </interface>|}

let item_interface_xml name =
  Printf.sprintf
    {| <interface name="%s">
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
  <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
  <signal name="NewIcon"/>
  <signal name="NewToolTip"/>
 </interface>
|}
    name

let menu_interface_xml =
  {| <interface name="com.canonical.dbusmenu">
  <property name="Version" type="u" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="TextDirection" type="s" access="read"/>
  <property name="IconThemePath" type="as" access="read"/>
  <method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/><arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
  <method name="GetGroupProperties"><arg type="ai" direction="in"/><arg type="as" direction="in"/><arg type="a(ia{sv})" direction="out"/></method>
  <method name="GetProperty"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
  <method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
  <method name="EventGroup"><arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/></method>
  <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
  <method name="AboutToShowGroup"><arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/></method>
  <signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
 </interface>
|}

let introspection interfaces =
  Printf.sprintf
    {|<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
%s %s
</node>
|}
    interfaces standard_interfaces

type exported = {
  interfaces : string list;
  properties : unit -> (string * Dbus.value) list;
  xml : string;
  call : string -> Dbus.value list -> answer * (unit -> unit);
}

let objects t =
  [
    ( item_path,
      {
        interfaces = item_interfaces;
        properties = (fun () -> item_properties t);
        xml =
          introspection
            (String.concat "" (List.map item_interface_xml item_interfaces));
        call = (fun member _ -> (item_call member, ignore));
      } );
    ( menu_path,
      {
        interfaces = [menu_interface];
        properties = (fun () -> menu_properties);
        xml = introspection menu_interface_xml;
        call = menu_call t;
      } );
  ]

let machine_id () =
  List.find_map
    (fun file ->
      Option.map String.trim (Fs.read_file_opt file) |> function
      | Some "" -> None
      | id -> id)
    ["/etc/machine-id"; "/var/lib/dbus/machine-id"]

let standard_members =
  ["Get"; "GetAll"; "Set"; "Introspect"; "Ping"; "GetMachineId"]

(* §3.2: every call gets an answer. *)
let answer_call exported ~interface ~member arguments =
  let known i = List.mem i exported.interfaces in
  let unknown_interface i =
    Refuse (error "UnknownInterface", "no interface " ^ i)
  in
  let standard () =
    match (member, arguments) with
      | "Get", [Dbus.String i; String name] ->
          if not (known i) then unknown_interface i
          else (
            match List.assoc_opt name (exported.properties ()) with
              | Some v -> Return [Variant v]
              | None -> Refuse (error "UnknownProperty", "no property " ^ name))
      | "GetAll", [Dbus.String i] ->
          if known i then Return [dictionary (exported.properties ())]
          else unknown_interface i
      | "Set", _ ->
          Refuse (error "PropertyReadOnly", "every property is read-only")
      | "Introspect", [] -> Return [String exported.xml]
      | "Ping", [] -> Return []
      | "GetMachineId", [] -> (
          match machine_id () with
            | Some id -> Return [String id]
            | None -> Refuse (error "Failed", "no machine id"))
      | _ -> invalid
  in
  let standard_interface =
    match member with
      | "Get" | "GetAll" | "Set" -> properties_interface
      | "Introspect" -> "org.freedesktop.DBus.Introspectable"
      | _ -> "org.freedesktop.DBus.Peer"
  in
  let is_standard = List.mem member standard_members in
  if interface = "" then
    if is_standard then (standard (), ignore)
    else exported.call member arguments
  else if known interface then exported.call member arguments
  else if
    List.mem interface
      [
        properties_interface;
        "org.freedesktop.DBus.Introspectable";
        "org.freedesktop.DBus.Peer";
      ]
  then
    if is_standard && interface = standard_interface then (standard (), ignore)
    else (Unknown_method, ignore)
  else (unknown_interface interface, ignore)

let register t =
  match
    Bus.call t.bus ~timeout:watcher_timeout ~destination:watcher
      ~path:watcher_path ~interface:watcher ~member:"RegisterStatusNotifierItem"
      [String t.item_name]
  with
    | Ok _ -> Log.debug "tray: registered with the watcher"
    | Error reason -> Log.debug "tray: not registered: %s" reason

let host_registered t =
  match
    Bus.call t.bus ~timeout:watcher_timeout ~destination:watcher
      ~path:watcher_path ~interface:properties_interface ~member:"Get"
      [String watcher; String "IsStatusNotifierHostRegistered"]
  with
    | Ok [Variant (Bool true)] -> true
    | _ -> false

let dispatch t exported message =
  match Dbus.kind message with
    | Signal ->
        if Dbus.member message = "NameOwnerChanged" then (
          match Dbus.body message with
            | [String name; _; String owner] when name = watcher && owner <> ""
              ->
                Rt.spawn ~name:"tray register" (fun () ->
                    register t;
                    locked t (fun () ->
                        item_signal t "NewIcon";
                        item_signal t "NewToolTip"))
            | _ -> ())
    | Method_call ->
        let answer, after =
          match List.assoc_opt (Dbus.path message) exported with
            | None -> (Unknown_method, ignore)
            | Some exported -> (
                try
                  answer_call exported ~interface:(Dbus.interface message)
                    ~member:(Dbus.member message) (Dbus.body message)
                with e ->
                  (Refuse (error "Failed", Printexc.to_string e), ignore))
        in
        if not (Dbus.no_reply message) then (
          let failed text =
            Dbus.error_reply message ~name:(error "Failed") text
          in
          Bus.send t.bus
            (match answer with
              | Return values -> (
                  try Dbus.method_return message values
                  with Dbus.Error text -> failed text)
              | Refuse (name, text) -> (
                  try Dbus.error_reply message ~name text
                  with Dbus.Error text -> failed text)
              | Unknown_method ->
                  Dbus.error_reply message ~name:(error "UnknownMethod")
                    "no such method"));
        after ()
    | Method_return | Error_reply -> ()

(* §2 step 1: the tray never lets a bus be started for it. *)
let bus_address () =
  match Sys.getenv_opt "DBUS_SESSION_BUS_ADDRESS" with
    | Some address when address <> "" -> Some address
    | _ -> (
        match Sys.getenv_opt "XDG_RUNTIME_DIR" with
          | Some dir when dir <> "" -> (
              let socket = Filename.concat dir "bus" in
              match Unix.stat socket with
                | { st_kind = S_SOCK; _ } -> Some ("unix:path=" ^ socket)
                | _ | (exception Unix.Unix_error _) -> None)
          | _ -> None)

let bus_call bus member arguments =
  Bus.call bus ~timeout:watcher_timeout ~destination:"org.freedesktop.DBus"
    ~path:"/org/freedesktop/DBus" ~interface:"org.freedesktop.DBus" ~member
    arguments

(* Without queueing: 1 is ownership, 4 that this connection owns it already. *)
let claim bus name =
  match bus_call bus "RequestName" [String name; Uint32 4] with
    | Ok [Uint32 (1 | 4)] -> `Owner
    | Ok [Uint32 _] -> `Taken
    | _ -> `Failed

let poll t =
  let rec loop due =
    (try refresh t
     with e when not (Rt.is_cancelled e) ->
       Log.warn "tray: refresh failed: %s" (Printexc.to_string e));
    let now = Rt.now () in
    let due = Float.max (due +. poll_interval) now in
    Rt.sleep (due -. now);
    loop due
  in
  loop (Rt.now ())

let serve bus =
  let t =
    {
      bus;
      item_name =
        Printf.sprintf "org.kde.StatusNotifierItem-%d-1" (Unix.getpid ());
      lock = Mutex.create ();
      layout = Layout.create ();
      icon = "tsync-idle-symbolic";
      tooltip = "tsync";
      domains = [];
      reported_mounts = [];
      stats_started = neg_infinity;
      refreshing = Rt.Fmutex.create ();
      finished = Rt.Promise.create ();
    }
  in
  let exported = ref [] in
  Rt.spawn ~name:"tray bus" (fun () ->
      Bus.serve bus (fun message -> dispatch t !exported message);
      ignore (Rt.Promise.try_resolve t.finished 0));
  match claim bus "org.tsync.Tray" with
    | `Taken ->
        print_endline "tsync-tray is already running";
        0
    | `Failed ->
        prerr_endline "tsync-tray: cannot claim org.tsync.Tray";
        1
    | `Owner -> (
        exported := objects t;
        match claim bus t.item_name with
          | `Taken | `Failed ->
              prerr_endline ("tsync-tray: cannot claim " ^ t.item_name);
              1
          | `Owner ->
              Rt.spawn ~name:"tray watcher" (fun () ->
                  ignore
                    (bus_call bus "AddMatch"
                       [
                         String
                           (Printf.sprintf
                              "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='%s'"
                              watcher);
                       ]);
                  register t;
                  if not (host_registered t) then
                    Log.warn
                      "tray: no StatusNotifier host is running, so nothing \
                       will draw the icon; on GNOME this needs the \
                       AppIndicator extension");
              Rt.spawn ~name:"tray poll" (fun () -> poll t);
              Rt.Promise.await t.finished)

let run () =
  match bus_address () with
    | None ->
        prerr_endline
          "tsync-tray: no session bus: the tray needs a running desktop session";
        1
    | Some address -> (
        match Bus.connect address with
          | bus -> serve bus
          | exception Dbus.Error reason ->
              prerr_endline ("tsync-tray: no session bus: " ^ reason);
              1)
