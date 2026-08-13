let iface = "com.canonical.dbusmenu"
let properties = "org.freedesktop.DBus.Properties"
let introspectable = "org.freedesktop.DBus.Introspectable"
let peer = "org.freedesktop.DBus.Peer"

(* Some hosts never send the closing event, and a menu that only swapped its
   contents on close would then hold its first contents forever. *)
let open_for_at_most = 60.

type row = { entry : Tray_model.entry; id : int; children : row list }

type t = {
  conn : Dbus.connection;
  path : string;
  mutable rows : row list;
  mutable pending : Tray_model.entry list option;
  mutable revision : int;
  mutable next_id : int;
  mutable opened_at : float option;
  mutable click : Tray_model.action -> unit;
  mutable opened : unit -> unit;
}

let on_click t f = t.click <- f
let on_open t f = t.opened <- f

let is_open t =
  match t.opened_at with
    | Some at -> Unix.gettimeofday () -. at < open_for_at_most
    | None -> false

(* dbusmenu reads a lone underscore as the mnemonic marker and eats it, so a
   file called my_photo_01.jpg would be drawn as myphoto01.jpg. *)
let escape_mnemonics label = String.concat "__" (String.split_on_char '_' label)

let props_of_entry (entry : Tray_model.entry) =
  match entry with
    | Tray_model.Separator -> [("type", Dbus.String "separator")]
    | Item i ->
        (* The macOS menu indents a file under its domain; dbusmenu has no
           property for that, so the nesting is spent on leading space. *)
        let label =
          String.make (4 * i.Tray_model.indent) ' ' ^ i.Tray_model.label
        in
        [
          ("label", Dbus.String (escape_mnemonics label));
          ("enabled", Dbus.Bool i.Tray_model.enabled);
          (* Sent rather than left to default: hosts disagree about what an
             absent "visible" means. *)
          ("visible", Dbus.Bool true);
        ]
        @ (match i.Tray_model.icon with
          | Some name -> [("icon-name", Dbus.String name)]
          | None -> [])
        @ (match i.Tray_model.checked with
          | Some on ->
              [
                ("toggle-type", Dbus.String "checkmark");
                ("toggle-state", Dbus.Int32 (if on then 1l else 0l));
              ]
          | None -> [])
        @
        (* The one property that makes a row open a menu instead of doing
           something. It comes from the model rather than from whether children
           happen to have arrived yet: a row that drew as an ordinary one until
           its contents loaded would move under the pointer. *)
        if i.Tray_model.submenu then
          [("children-display", Dbus.String "submenu")]
        else []

(* Only what was asked for. An empty request means everything, which is what
   every host actually sends. *)
let filter_props names props =
  if names = [] then props
  else List.filter (fun (k, _) -> List.mem k names) props

let node ~id ~props ~children =
  Dbus.Struct
    [
      Dbus.Int32 (Int32.of_int id);
      Dbus.dict_sv props;
      Dbus.Array ("v", children);
    ]

(* [depth] is the host's recursionDepth: 0 stops at this level and -1 means all
   of it, which is why it is counted down rather than tested for positive. *)
let rec node_of names depth r =
  node ~id:r.id
    ~props:(filter_props names (props_of_entry r.entry))
    ~children:
      (if depth = 0 then []
       else
         List.map
           (fun c -> Dbus.Variant (node_of names (depth - 1) c))
           r.children)

let rec find_row id rows =
  List.find_map
    (fun r -> if r.id = id then Some r else find_row id r.children)
    rows

(* Every row in the tree, for the lookups that are given an id and no idea where
   it sits. *)
let rec all_rows rows = List.concat_map (fun r -> r :: all_rows r.children) rows

let layout t names depth parent =
  match parent with
    | 0 ->
        node ~id:0
          ~props:
            (filter_props names [("children-display", Dbus.String "submenu")])
          ~children:
            (if depth = 0 then []
             else
               List.map
                 (fun r -> Dbus.Variant (node_of names (depth - 1) r))
                 t.rows)
    (* A host that was told one subtree changed asks for that subtree. An id
       that has since gone is answered with an empty node rather than an error:
       it is a layout the host is about to be told to drop anyway. *)
    | id -> (
        match find_row id t.rows with
          | Some r -> node_of names depth r
          | None -> node ~id ~props:[] ~children:[])

let submenu_action = function
  | Tray_model.Item i when i.Tray_model.submenu -> Some i.Tray_model.action
  | _ -> None

(* Rows are matched by position below, which a row that moved does not survive.
   A submenu is found by what it does instead, so that one new domain row above
   it does not leave the stats empty until the next time it is opened -- and a
   submenu with nothing in it is one some panels decline to open at all. *)
let adopted previous entry =
  match submenu_action entry with
    | None -> []
    | Some action -> (
        match
          List.find_opt (fun r -> submenu_action r.entry = Some action) previous
        with
          | Some r -> r.children
          | None -> [])

(* A row that did not change keeps its id; anything else gets a fresh one, and
   ids are never reused. So a click naming a row that has since changed is
   dropped rather than firing whatever took its place -- with rows appearing and
   disappearing every three seconds, that is a real way to reveal the wrong file
   -- while a click on a row that only sat there still works, which it would not
   if one changed label retired the whole tree.

   A row's children are this module's state rather than the model's, which only
   marks that there is a submenu, so they survive that redraw too: otherwise the
   poll three seconds after the stats arrived would put the placeholder back. *)
let build t previous entries =
  List.mapi
    (fun i entry ->
      let kept =
        match List.nth_opt previous i with
          | Some r when r.entry = entry -> Some r
          | _ -> None
      in
      match kept with
        | Some r -> r
        | None ->
            let id = t.next_id in
            t.next_id <- id + 1;
            { entry; id; children = adopted previous entry })
    entries

(* [parent] is what the host is told changed: the root for a new menu, one row
   for a submenu that has just been filled in. Naming the row rather than the
   root is what keeps an open menu from being torn down around it. *)
let announce t parent =
  t.revision <- t.revision + 1;
  Dbus.emit t.conn ~path:t.path ~iface ~member:"LayoutUpdated"
    [Dbus.Uint32 (Int32.of_int t.revision); Dbus.Int32 (Int32.of_int parent)]

let install t entries =
  t.rows <- build t t.rows entries;
  announce t 0

(* Fill in one row's submenu, leaving the rest of the tree and its ids alone.
   Announced against that row rather than the root, which is what lets it happen
   under a menu that is already open: the host refetches the one subtree instead
   of dropping the menu it is drawing. *)
let set_children t action entries =
  match
    List.find_opt
      (fun r ->
        match r.entry with
          | Tray_model.Item i -> i.Tray_model.action = action
          | Separator -> false)
      t.rows
  with
    | None -> ()
    | Some parent ->
        let current = List.map (fun r -> r.entry) parent.children in
        if entries <> current then (
          let filled =
            { parent with children = build t parent.children entries }
          in
          t.rows <-
            List.map (fun r -> if r.id = parent.id then filled else r) t.rows;
          announce t parent.id)

let set t entries =
  let current = List.map (fun r -> r.entry) t.rows in
  (* An unchanged menu is not reinstalled. Every install mints new ids, so
     reinstalling on each poll would retire the ids the host is holding every
     three seconds, and a click that took longer than that to arrive would name
     a row that no longer exists. *)
  if entries = current then t.pending <- None
    (* Rebuilding under an open menu dismisses it, which is how a menu becomes
       impossible to click. Hold it instead; the close installs it. *)
  else if is_open t then t.pending <- Some entries
  else install t entries

let close t =
  t.opened_at <- None;
  match t.pending with
    | Some entries ->
        t.pending <- None;
        install t entries
    | None -> ()

let introspection =
  Dbus.introspection
    {xml|  <interface name="com.canonical.dbusmenu">
    <property name="Version" type="u" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="TextDirection" type="s" access="read"/>
    <property name="IconThemePath" type="as" access="read"/>
    <method name="GetLayout">
      <arg name="parentId" type="i" direction="in"/>
      <arg name="recursionDepth" type="i" direction="in"/>
      <arg name="propertyNames" type="as" direction="in"/>
      <arg name="revision" type="u" direction="out"/>
      <arg name="layout" type="(ia{sv}av)" direction="out"/>
    </method>
    <method name="GetGroupProperties">
      <arg name="ids" type="ai" direction="in"/>
      <arg name="propertyNames" type="as" direction="in"/>
      <arg name="properties" type="a(ia{sv})" direction="out"/>
    </method>
    <method name="GetProperty">
      <arg name="id" type="i" direction="in"/>
      <arg name="name" type="s" direction="in"/>
      <arg name="value" type="v" direction="out"/>
    </method>
    <method name="Event">
      <arg name="id" type="i" direction="in"/>
      <arg name="eventId" type="s" direction="in"/>
      <arg name="data" type="v" direction="in"/>
      <arg name="timestamp" type="u" direction="in"/>
    </method>
    <method name="EventGroup">
      <arg name="events" type="a(isvu)" direction="in"/>
      <arg name="idErrors" type="ai" direction="out"/>
    </method>
    <method name="AboutToShow">
      <arg name="id" type="i" direction="in"/>
      <arg name="needUpdate" type="b" direction="out"/>
    </method>
    <method name="AboutToShowGroup">
      <arg name="ids" type="ai" direction="in"/>
      <arg name="updatesNeeded" type="ai" direction="out"/>
      <arg name="idErrors" type="ai" direction="out"/>
    </method>
    <signal name="LayoutUpdated">
      <arg name="revision" type="u"/>
      <arg name="parent" type="i"/>
    </signal>
    <signal name="ItemsPropertiesUpdated">
      <arg name="updatedProps" type="a(ia{sv})"/>
      <arg name="removedProps" type="a(ias)"/>
    </signal>
  </interface>
|xml}

let menu_props =
  [
    ("Version", Dbus.Uint32 3l);
    ("Status", Dbus.String "normal");
    ("TextDirection", Dbus.String "ltr");
    ("IconThemePath", Dbus.Array ("s", []));
  ]

let strings = List.filter_map (function Dbus.String s -> Some s | _ -> None)

let ints =
  List.filter_map (function Dbus.Int32 n -> Some (Int32.to_int n) | _ -> None)

let arg_strings = function Dbus.Array (_, vs) -> strings vs | _ -> []
let arg_ints = function Dbus.Array (_, vs) -> ints vs | _ -> []

(* The row a click names, or None when the tree it belonged to is gone. *)
let row t id = find_row id t.rows

let action_of_row r =
  match r.entry with
    | Tray_model.Item i when i.Tray_model.enabled -> Some i.Tray_model.action
    | _ -> None

let handle_menu t msg =
  let reply = Dbus.reply t.conn msg in
  match (Dbus.message_member msg, Dbus.body msg) with
    | "GetLayout", [Dbus.Int32 parent; Dbus.Int32 depth; names] ->
        reply
          [
            Dbus.Uint32 (Int32.of_int t.revision);
            layout t (arg_strings names) (Int32.to_int depth)
              (Int32.to_int parent);
          ]
    | "GetGroupProperties", [ids; names] ->
        let wanted = arg_ints ids and names = arg_strings names in
        let rows = all_rows t.rows in
        let rows =
          if wanted = [] then rows
          else List.filter (fun r -> List.mem r.id wanted) rows
        in
        reply
          [
            Dbus.Array
              ( "(ia{sv})",
                List.map
                  (fun r ->
                    Dbus.Struct
                      [
                        Dbus.Int32 (Int32.of_int r.id);
                        Dbus.dict_sv
                          (filter_props names (props_of_entry r.entry));
                      ])
                  rows );
          ]
    | "GetProperty", [Dbus.Int32 id; Dbus.String name] -> (
        match
          Option.bind
            (row t (Int32.to_int id))
            (fun r -> List.assoc_opt name (props_of_entry r.entry))
        with
          | Some v -> reply [Dbus.Variant v]
          | None -> reply [Dbus.Variant (Dbus.String "")])
    (* Answered before the hook runs, not after: filling a submenu means asking
       every daemon, and a host waiting on this reply is a menu that has not
       appeared yet. What the hook installs arrives as its own LayoutUpdated,
       which is what that signal is for. *)
    | "AboutToShow", [Dbus.Int32 _] ->
        t.opened_at <- Some (Unix.gettimeofday ());
        (* [false]: the layout is already current, and claiming otherwise makes
           a host refetch on every open for nothing. *)
        reply [Dbus.Bool false];
        Dbus.flush t.conn;
        t.opened ()
    | "AboutToShowGroup", [_] ->
        t.opened_at <- Some (Unix.gettimeofday ());
        reply [Dbus.Array ("i", []); Dbus.Array ("i", [])];
        Dbus.flush t.conn;
        t.opened ()
    | "Event", [Dbus.Int32 id; Dbus.String event; _; _] -> (
        (* Answered before acting, always: opening a file manager blocks, and a
           menu that has not been let go of looks stuck. *)
        reply [];
        Dbus.flush t.conn;
        match event with
          | "opened" ->
              t.opened_at <- Some (Unix.gettimeofday ());
              t.opened ()
          | "closed" -> close t
          | "clicked" -> (
              match Option.bind (row t (Int32.to_int id)) action_of_row with
                | Some action -> t.click action
                | None -> Log.debug "tray: click on a stale item %ld" id)
          | _ -> ())
    | "EventGroup", [_] -> reply [Dbus.Array ("i", [])]
    | _ -> Dbus.unknown_method t.conn msg

let handle_properties t msg =
  match (Dbus.message_member msg, Dbus.body msg) with
    | "Get", [Dbus.String _; Dbus.String name] -> (
        match List.assoc_opt name menu_props with
          | Some v -> Dbus.reply t.conn msg [Dbus.Variant v]
          | None -> Dbus.unknown_property t.conn msg name)
    | "GetAll", _ -> Dbus.reply t.conn msg [Dbus.dict_sv menu_props]
    | "Set", _ -> Dbus.read_only_property t.conn msg
    | _ -> Dbus.unknown_method t.conn msg

let handle t msg =
  if Dbus.message_path msg <> t.path then false
  else (
    let requested = Dbus.message_interface msg in
    if requested = properties then handle_properties t msg
    else if requested = introspectable then
      Dbus.reply t.conn msg [Dbus.String introspection]
    else if requested = peer then Dbus.reply t.conn msg []
    else if requested = iface then handle_menu t msg
    else Dbus.unknown_interface t.conn msg;
    true)

let create conn ~path =
  {
    conn;
    path;
    rows = [];
    pending = None;
    revision = 1;
    (* Not from zero: zero is the root, and starting the rows above it keeps a
       stale id from ever colliding with it. *)
    next_id = 1;
    opened_at = None;
    click = (fun _ -> ());
    opened = (fun () -> ());
  }
