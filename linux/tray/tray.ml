open Tsync_core
open Tsync_config
open Tsync_dbus
open Tsync_menu
open Tsync_tray_core
module M = Menu_model

(* §10. *)
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

(* [lock] guards every mutable field and the layout; it is never held across
   a wait. *)
type t = {
  bus : Bus.t;
  item_name : string;
  lock : Mutex.t;
  layout : Layout.t;
  mutable icon : string;
  mutable tooltip : string;
  mutable core : Tray_core.t option;
}

let locked t f = Mutex.protect t.lock f
let core t = Option.get t.core

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

(* §6.5: each code domain's vault mark, by domain, as fetched at the last
   opening. One tray runs per process (§2 step 3). *)
let marks : (string * string) list Atomic.t = Atomic.make []

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
      @ (match i.vault with
        | Some domain -> (
            match List.assoc_opt domain (Atomic.get marks) with
              | Some png -> [("icon-data", Dbus.byte_array png)]
              | None -> [])
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

let on_path program =
  List.exists
    (fun dir -> dir <> "" && Sys.file_exists (Filename.concat dir program))
    (String.split_on_char ':'
       (Option.value (Sys.getenv_opt "PATH") ~default:""))

(* §6.5: of the domains whose status lists totp, those whose codes this tray
   can copy. *)
let code_domains listed =
  match listed with
    | [] -> []
    | listed -> (
        match (Sys.getenv_opt "WAYLAND_DISPLAY", on_path "wl-copy") with
          | Some display, true when display <> "" -> listed
          | Some display, false when display <> "" ->
              Log.once "tray-codes-wl-copy" Log.Warn
                "tray: no one-time codes: wl-copy (wl-clipboard) is not \
                 installed";
              []
          | _ ->
              Log.once "tray-codes-wayland" Log.Warn
                "tray: no one-time codes: they are copied on Wayland only";
              [])

(* A refresh's menu, drawn: new icon and tooltip signalled, the rows held back
   while the menu is open (§4.3). *)
let set_menu t (menu : M.t) =
  locked t (fun () ->
      if menu.icon <> t.icon then (
        t.icon <- menu.icon;
        item_signal t "NewIcon");
      if menu.tooltip <> t.tooltip then (
        t.tooltip <- menu.tooltip;
        item_signal t "NewToolTip");
      announce t (Layout.set_menu t.layout ~now:(Rt.now ()) menu.entries))

let notify t summary body =
  match
    Bus.call t.bus ~timeout:file_manager_timeout
      ~destination:"org.freedesktop.Notifications"
      ~path:"/org/freedesktop/Notifications"
      ~interface:"org.freedesktop.Notifications" ~member:"Notify"
      [
        String "tsync";
        Uint32 0;
        String "tsync";
        String summary;
        String body;
        Array ("s", []);
        Array ("{sv}", []);
        Int32 (-1);
      ]
  with
    | Ok _ -> ()
    | Error reason ->
        Log.warn "tray: %s: %s (no notification: %s)" summary body reason

(* The helper's standard output, or [None] when it failed or was closed; its
   exit is awaited on a thread of its own, since a dialog stays open for as long
   as the user leaves it. Without [capture] its output goes to /dev/null: a
   helper that leaves a child behind holding it, as wl-copy does, would keep
   the read open. *)
let helper ?input ?(capture = true) program arguments =
  Rt.within `Threaded (fun () ->
      let stdin_read, stdin_write = Unix.pipe ~cloexec:true () in
      let stdout_read, stdout_write =
        if capture then Unix.pipe ~cloexec:true ()
        else (
          let null = Unix.openfile "/dev/null" [O_WRONLY; O_CLOEXEC] 0 in
          (Unix.dup ~cloexec:true null, null))
      in
      match
        Unix.create_process program
          (Array.of_list (program :: arguments))
          stdin_read stdout_write Unix.stderr
      with
        | exception Unix.Unix_error (e, _, _) ->
            List.iter Unix.close
              [stdin_read; stdin_write; stdout_read; stdout_write];
            Log.warn "tray: cannot run %s: %s" program (Unix.error_message e);
            None
        | pid -> (
            Unix.close stdin_read;
            Unix.close stdout_write;
            (* A helper that exits without reading leaves the pipe closed. *)
            (try
               Option.iter
                 (fun s ->
                   ignore
                     (Unix.write_substring stdin_write s 0 (String.length s)))
                 input
             with Unix.Unix_error _ -> ());
            Unix.close stdin_write;
            let output =
              if capture then
                In_channel.input_all (Unix.in_channel_of_descr stdout_read)
              else ""
            in
            Unix.close stdout_read;
            match snd (Unix.waitpid [] pid) with
              | WEXITED 0 -> Some output
              | _ -> None))

(* security-model §10.6: the code goes on standard input, never in arguments,
   and the clipboard is never cleared. *)
let copy code =
  match
    helper ~input:code ~capture:false "wl-copy"
      ["--sensitive"; "--type"; "text/plain"]
  with
    | Some _ -> Ok ()
    | None -> Error "wl-copy did not take it"

let dialog ~title text =
  Option.map
    (fun answer ->
      if String.ends_with ~suffix:"\n" answer then
        String.sub answer 0 (String.length answer - 1)
      else answer)
    (helper "kdialog" ["--title"; title; "--password"; text])

(* §4.4. Answers whether the layout under [id] changed, and the work to start
   once the reply is sent. *)
let opening t id =
  let changed =
    change_layout t (fun layout -> Layout.opening layout ~now:(Rt.now ()) id)
  in
  (changed, fun () -> Tray_core.opened (core t))

let click t id =
  match locked t (fun () -> Layout.find t.layout id) with
    | Some { entry = Item { enabled = true; action; _ }; _ } ->
        Rt.spawn ~name:"tray action" (fun () ->
            Tray_core.run_action (core t) action)
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

(* The Linux platform of the shared tray (linux-tray.md §5–§7). *)
let platform t =
  {
    Tray_core.menu = set_menu t;
    children =
      (fun action rows ->
        ignore
          (change_layout t (fun layout ->
               Layout.set_children layout action rows)));
    marks = Atomic.set marks;
    notify = notify t;
    copy;
    show = show t;
    ask_secret = dialog;
    can_ask =
      (fun () ->
        if on_path "kdialog" then Ok () else Error "kdialog is not installed.");
    code_domains;
    configured_folder = Mounts.configured;
  }

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
      core = None;
    }
  in
  let core = Tray_core.create ~quit:"Quit tsync tray" (platform t) in
  t.core <- Some core;
  let exported = ref [] in
  Rt.spawn ~name:"tray bus" (fun () ->
      Bus.serve bus (fun message -> dispatch t !exported message);
      ignore (Rt.Promise.try_resolve (Tray_core.finished core) 0));
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
              Rt.spawn ~name:"tray poll" (fun () -> Tray_core.poll core);
              Rt.Promise.await (Tray_core.finished core))

let run () =
  match Dbus.session_address () with
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
