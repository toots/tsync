(* The tray as a process on a private session bus, with a scripted host
   (linux-tray.md §9). Scenarios run side by side, each on its own bus; a
   scenario's lines are printed together, in a fixed order. *)
open Tsync_core
open Tsync_dbus
open Tsync_tray_lib

let tray_exe = Filename.concat (Sys.getcwd ()) Sys.argv.(1)
let owner_double = Filename.concat (Sys.getcwd ()) Sys.argv.(2)
let root = Printf.sprintf "/tmp/tt-%d" (Unix.getpid ())
let poll_interval = 3.
let status_deadline = 1.5
let bus_answer_bound = 0.1

(* Time allowed on top of a bound the spec states, for a loaded machine. *)
let margin = 1.

let write file text =
  Fs.mkdir_p ~perm:0o700 (Filename.dirname file);
  let temporary = file ^ ".new" in
  let oc = open_out_gen [Open_wronly; Open_creat; Open_trunc] 0o600 temporary in
  output_string oc text;
  close_out oc;
  Unix.rename temporary file

let read file = Option.value ~default:"" (Fs.read_file_opt file)
let lines file = List.filter (( <> ) "") (String.split_on_char '\n' (read file))

let rec wait_until ?(timeout = 10.) condition =
  condition ()
  || timeout > 0.
     &&
     (Rt.sleep 0.05;
      wait_until ~timeout:(timeout -. 0.05) condition)

let children = ref []
let children_lock = Mutex.create ()

let spawn ?(env = Unix.environment ()) ?(out = Unix.stdout) ?(err = Unix.stderr)
    program arguments =
  let pid =
    Unix.create_process_env program
      (Array.of_list (program :: arguments))
      env Unix.stdin out err
  in
  Mutex.protect children_lock (fun () -> children := pid :: !children);
  pid

type signal = { at : float; member : string; arguments : Dbus.value list }

(* One scenario's bus, directories, host connection and what the host saw. *)
type world = {
  dir : string;
  address : string;
  daemon : int;
  host : Bus.t;
  lock : Mutex.t;
  mutable signals : signal list;
  mutable registrations : string list;
  mutable file_manager : (string * string) list;
  mutable file_manager_answers : bool;
  mutable tray : int;
  out : Buffer.t;
}

let say w fmt =
  Printf.ksprintf (fun s -> Buffer.add_string w.out (s ^ "\n")) fmt

let check w title ok = say w "%s: %s" title (if ok then "yes" else "NO")
let locked w f = Mutex.protect w.lock f
let path w = Filename.concat w.dir
let item w = Printf.sprintf "org.kde.StatusNotifierItem-%d-1" w.tray
let watcher = "org.kde.StatusNotifierWatcher"
let file_manager = "org.freedesktop.FileManager1"

let host_handler w message =
  let reply values = Bus.send w.host (Dbus.method_return message values) in
  match (Dbus.kind message, Dbus.interface message, Dbus.member message) with
    | Signal, _, member ->
        locked w (fun () ->
            w.signals <-
              { at = Rt.now (); member; arguments = Dbus.body message }
              :: w.signals)
    | Method_call, _, "RegisterStatusNotifierItem" ->
        (match Dbus.body message with
          | [String name] ->
              locked w (fun () -> w.registrations <- name :: w.registrations)
          | _ -> ());
        reply []
    | Method_call, "org.freedesktop.DBus.Properties", "Get" ->
        reply [Variant (Bool true)]
    | Method_call, _, (("ShowFolders" | "ShowItems") as member) ->
        (match Dbus.body message with
          | [Array (_, [String uri]); String _] ->
              locked w (fun () ->
                  w.file_manager <- (member, uri) :: w.file_manager)
          | _ -> ());
        if locked w (fun () -> w.file_manager_answers) then reply []
    | Method_call, _, _ ->
        Bus.send w.host
          (Dbus.error_reply message
             ~name:"org.freedesktop.DBus.Error.UnknownMethod" "no")
    | _ -> ()

let bus_call ?(connection : Bus.t option) w member arguments =
  Bus.call
    (Option.value ~default:w.host connection)
    ~timeout:5. ~destination:"org.freedesktop.DBus"
    ~path:"/org/freedesktop/DBus" ~interface:"org.freedesktop.DBus" ~member
    arguments

let own ?connection w name =
  ignore (bus_call ?connection w "RequestName" [String name; Uint32 4])

let has_owner w name = bus_call w "NameHasOwner" [String name] = Ok [Bool true]
let counter = ref 0
let counter_lock = Mutex.create ()

let world () =
  let n =
    Mutex.protect counter_lock (fun () ->
        incr counter;
        !counter)
  in
  let dir = Printf.sprintf "%s/%d" root n in
  List.iter
    (fun d -> Fs.mkdir_p ~perm:0o700 (Filename.concat dir d))
    ["h"; "c/tsync"; "d/tsync"; "bin"; "rt"];
  (* The bus has no service directory: the system's session configuration
     would start the real file manager for a call to its name. *)
  write
    (Filename.concat dir "bus.conf")
    (Printf.sprintf
       {|<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=%s</listen>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
|}
       (Filename.concat dir "rt/bus"));
  let read_end, write_end = Unix.pipe ~cloexec:false () in
  let daemon =
    spawn ~out:write_end "dbus-daemon"
      [
        "--config-file=" ^ Filename.concat dir "bus.conf";
        "--nofork";
        "--print-address=1";
      ]
  in
  Unix.close write_end;
  let ic = Unix.in_channel_of_descr read_end in
  let address = input_line ic in
  close_in ic;
  write
    (Filename.concat dir "bin/xdg-open")
    (Printf.sprintf "#!/bin/sh\necho \"$1\" >> %s/xdg-open.log\n" dir);
  Unix.chmod (Filename.concat dir "bin/xdg-open") 0o700;
  let w =
    {
      dir;
      address;
      daemon;
      host = Bus.connect address;
      lock = Mutex.create ();
      signals = [];
      registrations = [];
      file_manager = [];
      file_manager_answers = true;
      tray = 0;
      out = Buffer.create 1024;
    }
  in
  Rt.spawn ~name:"host" (fun () -> Bus.serve w.host (host_handler w));
  ignore (bus_call w "AddMatch" [String "type='signal'"]);
  w

let environment ?(address = true) ?(runtime = false) w =
  let dropped =
    [
      "HOME="; "XDG_"; "DBUS_SESSION_BUS_ADDRESS="; "TSYNC_CONFIG_JSON="; "PATH=";
    ]
  in
  Array.of_list
    ([
       "HOME=" ^ path w "h";
       "XDG_CONFIG_HOME=" ^ path w "c";
       "XDG_DATA_HOME=" ^ path w "d";
       "PATH=" ^ path w "bin" ^ ":" ^ Sys.getenv "PATH";
     ]
    @ (if address then ["DBUS_SESSION_BUS_ADDRESS=" ^ w.address] else [])
    @ (if runtime then ["XDG_RUNTIME_DIR=" ^ path w "rt"] else [])
    @ List.filter
        (fun v ->
          not (List.exists (fun prefix -> String.starts_with ~prefix v) dropped))
        (Array.to_list (Unix.environment ())))

let run_tray ?address ?runtime ?(arguments = []) w =
  let file name =
    Unix.openfile (path w name) [O_WRONLY; O_CREAT; O_APPEND] 0o600
  in
  let out = file "tray.out" and err = file "tray.err" in
  let pid =
    spawn ~env:(environment ?address ?runtime w) ~out ~err tray_exe arguments
  in
  Unix.close out;
  Unix.close err;
  pid

let start_tray w =
  w.tray <- run_tray w;
  if not (wait_until (fun () -> has_owner w (item w))) then
    failwith "the tray did not start"

let exit_status ?(timeout = 10.) pid =
  let status = ref None in
  ignore
    (wait_until ~timeout (fun () ->
         match Unix.waitpid [WNOHANG] pid with
           | 0, _ -> false
           | _, WEXITED code ->
               status := Some code;
               true
           | _ -> true));
  !status

let socket w name = path w (Printf.sprintf "d/tsync/tsync-%s.sock" name)
let script w name action = path w (Printf.sprintf "o-%s/%s" name action)

let configure w names =
  write
    (path w "c/tsync/config.json")
    (Printf.sprintf {|{"name":"test","domains":[%s]}|}
       (String.concat ","
          (List.map
             (fun name ->
               Printf.sprintf
                 {|{"name":%S,"symlinks":"keep","versioning":true,
                    "frontends":[{"type":"fuse","mountPoint":"/cfg/%s"}],
                    "backends":[{"type":"local","name":"main","role":"main","path":"/srv/%s"}]}|}
                 name name name)
             names)))

let owner ?(mode = "scripted") ?(status = {|{"ok":true}|}) w name =
  Fs.mkdir_p ~perm:0o700 (path w ("o-" ^ name));
  write (script w name "status") status;
  let null = Unix.openfile "/dev/null" [O_WRONLY] 0 in
  ignore
    (spawn ~out:null owner_double [mode; socket w name; path w ("o-" ^ name)]);
  Unix.close null;
  if not (wait_until (fun () -> Sys.file_exists (socket w name))) then
    failwith "an owner double did not start"

let requests w name action =
  List.length
    (List.filter
       (fun line ->
         Text.contains line (Printf.sprintf {|"action":"%s"|} action))
       (lines (script w name "requests")))

let call_at w ~path:object_path ~interface member arguments =
  Bus.call w.host ~timeout:5. ~destination:(item w) ~path:object_path ~interface
    ~member arguments

let menu w member arguments =
  call_at w ~path:"/MenuBar" ~interface:"com.canonical.dbusmenu" member
    arguments

type node = {
  id : int;
  properties : (string * Dbus.value) list;
  children : node list;
}

let rec node_of = function
  | Dbus.Struct [Int32 id; Array (_, properties); Array (_, children)] ->
      {
        id;
        properties =
          List.filter_map
            (function
              | Dbus.Dict_entry (String k, Variant v) -> Some (k, v) | _ -> None)
            properties;
        children =
          List.filter_map
            (function Dbus.Variant v -> Some (node_of v) | _ -> None)
            children;
      }
  | _ -> failwith "not a layout node"

let layout ?(parent = 0) ?(depth = -1) w =
  match menu w "GetLayout" [Int32 parent; Int32 depth; Array ("s", [])] with
    | Ok [Uint32 revision; root] -> (revision, node_of root)
    | _ -> failwith "GetLayout failed"

let label n =
  match List.assoc_opt "label" n.properties with
    | Some (String s) -> s
    | _ -> "---"

let rows w = (snd (layout w)).children
let labels w = List.map label (rows w)

let find w prefix =
  List.find_opt (fun n -> String.starts_with ~prefix (label n)) (rows w)

let row w prefix =
  match find w prefix with Some n -> n | None -> failwith ("no row " ^ prefix)

let shows w prefix = wait_until (fun () -> find w prefix <> None)

let click w id =
  ignore
    (menu w "Event" [Int32 id; String "clicked"; Variant (Int32 0); Uint32 0])

let event w id kind =
  ignore (menu w "Event" [Int32 id; String kind; Variant (Int32 0); Uint32 0])

let signals ?(since = 0.) w member =
  List.rev
    (List.filter
       (fun s -> s.member = member && s.at >= since)
       (locked w (fun () -> w.signals)))

let root_updates ?since w =
  List.filter
    (fun s -> match s.arguments with [_; Int32 0] -> true | _ -> false)
    (signals ?since w "LayoutUpdated")

let revisions_increase w =
  let rec increasing = function
    | a :: (b :: _ as rest) -> a < b && increasing rest
    | _ -> true
  in
  increasing
    (List.filter_map
       (fun s -> match s.arguments with [Uint32 r; _] -> Some r | _ -> None)
       (signals w "LayoutUpdated"))

let shown w = locked w (fun () -> List.rev w.file_manager)

let outcome = function
  | Ok _ -> "answered"
  | Error name -> (
      match String.rindex_opt name '.' with
        | Some i -> String.sub name (i + 1) (String.length name - i - 1)
        | None -> name)

let busy name size =
  Printf.sprintf
    {|{"ok":true,"pendingUploads":1,"uploading":[{"name":"%s","rel":"d/%s","size":%d}]}|}
    name name size

(* §9 "Every call is answered", "Labels". *)
let calls w =
  configure w ["photos"];
  owner w "photos"
    ~status:
      {|{"ok":true,"downloading":[{"name":"my_file_v2.txt","rel":"a/my_file_v2.txt","bytes":1,"size":2}]}|};
  start_tray w;
  ignore (shows w "photos — Downloading");
  let item_path = "/StatusNotifierItem"
  and properties = "org.freedesktop.DBus.Properties" in
  let show title result = say w "%-52s %s" title (outcome result) in
  List.iter
    (fun interface ->
      show (interface ^ " GetAll")
        (call_at w ~path:item_path ~interface:properties "GetAll"
           [String interface]);
      show
        (interface ^ " Get IconName")
        (call_at w ~path:item_path ~interface:properties "Get"
           [String interface; String "IconName"]);
      List.iter
        (fun (member, arguments) ->
          show
            (interface ^ " " ^ member)
            (call_at w ~path:item_path ~interface member arguments))
        [
          ("Activate", [Dbus.Int32 0; Int32 0]);
          ("SecondaryActivate", [Int32 0; Int32 0]);
          ("ContextMenu", [Int32 0; Int32 0]);
          ("Scroll", [Int32 1; String "vertical"]);
          ("Nope", []);
        ])
    ["org.kde.StatusNotifierItem"; "org.freedesktop.StatusNotifierItem"];
  show "item Get, unknown property"
    (call_at w ~path:item_path ~interface:properties "Get"
       [String "org.kde.StatusNotifierItem"; String "Nope"]);
  show "item Get, another interface"
    (call_at w ~path:item_path ~interface:properties "Get"
       [String "org.example.Other"; String "Id"]);
  show "item GetAll, another interface"
    (call_at w ~path:item_path ~interface:properties "GetAll"
       [String "org.example.Other"]);
  show "item Set"
    (call_at w ~path:item_path ~interface:properties "Set"
       [String "org.kde.StatusNotifierItem"; String "Id"; Variant (String "x")]);
  show "item Introspect"
    (call_at w ~path:item_path ~interface:"org.freedesktop.DBus.Introspectable"
       "Introspect" []);
  show "item Peer.Ping"
    (call_at w ~path:item_path ~interface:"org.freedesktop.DBus.Peer" "Ping" []);
  show "item Peer.GetMachineId"
    (call_at w ~path:item_path ~interface:"org.freedesktop.DBus.Peer"
       "GetMachineId" []);
  show "item, a known member on an unknown interface"
    (call_at w ~path:item_path ~interface:"org.example.Other" "Activate"
       [Int32 0; Int32 0]);
  show "item, no interface header, Activate"
    (call_at w ~path:item_path ~interface:"" "Activate" [Int32 0; Int32 0]);
  show "item, no interface header, GetAll"
    (call_at w ~path:item_path ~interface:"" "GetAll"
       [String "org.kde.StatusNotifierItem"]);
  show "item, no interface header, unknown member"
    (call_at w ~path:item_path ~interface:"" "Nope" []);
  show "an unknown path"
    (call_at w ~path:"/Elsewhere" ~interface:"org.kde.StatusNotifierItem"
       "Activate" [Int32 0; Int32 0]);
  let none = Dbus.Array ("s", []) in
  List.iter
    (fun (member, arguments) ->
      show ("menu " ^ member) (menu w member arguments))
    [
      ("GetLayout", [Dbus.Int32 0; Int32 (-1); none]);
      ("GetLayout", [Int32 9999; Int32 (-1); none]);
      ("GetGroupProperties", [Array ("i", []); none]);
      ("GetProperty", [Int32 9999; String "label"]);
      ("AboutToShow", [Int32 9999]);
      ("AboutToShowGroup", [Array ("i", [Int32 9999])]);
      ("Event", [Int32 9999; String "hovered"; Variant (Int32 0); Uint32 0]);
      ("EventGroup", [Array ("(isvu)", [])]);
      ("Nope", []);
      ("GetLayout", [String "wrong"]);
    ];
  show "menu GetAll"
    (call_at w ~path:"/MenuBar" ~interface:properties "GetAll"
       [String "com.canonical.dbusmenu"]);
  show "menu Introspect"
    (call_at w ~path:"/MenuBar" ~interface:"org.freedesktop.DBus.Introspectable"
       "Introspect" []);
  (match
     call_at w ~path:"/MenuBar" ~interface:properties "Get"
       [String "com.canonical.dbusmenu"; String "Version"]
   with
    | Ok [Variant (Uint32 v)] -> say w "dbusmenu Version: %d" v
    | _ -> say w "dbusmenu Version: ?");
  (match menu w "GetLayout" [Int32 9999; Int32 (-1); none] with
    | Ok [_; node] ->
        let n = node_of node in
        say w "a parent that names no row: id %d, %d properties, %d children"
          n.id (List.length n.properties) (List.length n.children)
    | _ -> say w "a parent that names no row: ?");
  (match menu w "GetProperty" [Int32 9999; String "label"] with
    | Ok [Variant (String s)] -> say w "a property of no row: %S" s
    | _ -> say w "a property of no row: ?");
  say w "depth 0 gives no children: %d"
    (List.length (snd (layout ~depth:0 w)).children);
  say w "depth 1 gives the rows without theirs: %b"
    (List.for_all (fun n -> n.children = []) (snd (layout ~depth:1 w)).children);
  say w "root properties: %s"
    (String.concat ", " (List.map fst (snd (layout w)).properties));
  List.iter
    (fun n ->
      say w "row \"%s\": %s" (label n)
        (String.concat ", "
           (List.filter_map
              (fun (k, v) ->
                match v with
                  | _ when k = "label" -> None
                  | Dbus.String s -> Some (k ^ "=" ^ s)
                  | Bool b -> Some (Printf.sprintf "%s=%b" k b)
                  | Int32 i -> Some (Printf.sprintf "%s=%d" k i)
                  | _ -> Some k)
              n.properties)))
    (rows w);
  check w "the revision increases" (revisions_increase w)

(* §9 "The bus is served while owners are silent". *)
let served w =
  configure w ["quiet"; "busy"];
  owner ~mode:"silent" w "quiet";
  owner w "busy";
  write (script w "busy" "pause") "silent";
  locked w (fun () -> w.file_manager_answers <- false);
  own w file_manager;
  start_tray w;
  ignore (shows w "busy — Idle");
  let worst = ref 0. in
  let sample seconds =
    let stop = Rt.now () +. seconds in
    while Rt.now () < stop do
      let started = Rt.now () in
      ignore (layout w);
      ignore
        (call_at w ~path:"/StatusNotifierItem"
           ~interface:"org.freedesktop.DBus.Properties" "GetAll"
           [String "org.kde.StatusNotifierItem"]);
      worst := Float.max !worst ((Rt.now () -. started) /. 2.);
      Rt.sleep 0.02
    done
  in
  sample (poll_interval +. 1.);
  ignore (menu w "AboutToShow" [Int32 0]);
  sample 2.;
  event w 0 "closed";
  click w (row w "busy").id;
  sample 2.;
  click w (row w "Hold changes").id;
  sample 2.;
  check w
    "GetLayout and GetAll within BUS_ANSWER_BOUND during a poll, a stats \
     fetch, a silent file manager and a hold switch"
    (!worst < bus_answer_bound);
  say w "the silent owner's row: %s" (label (row w "quiet"));
  check w "the stats fetch reached the silent owner"
    (wait_until (fun () -> requests w "busy" "stats" = 1));
  check w "the hold switch reached the other owner"
    (wait_until (fun () -> requests w "busy" "pause" = 1))

(* §9 "One silent owner costs one deadline". *)
let deadline ~silent count w =
  let names = List.init count (Printf.sprintf "d%02d") in
  configure w names;
  List.iteri
    (fun i name ->
      if i < silent then owner ~mode:"silent" w name
      else owner w name ~status:(busy "f.bin" 10))
    names;
  let started = Rt.now () in
  start_tray w;
  let current () =
    let labels = labels w in
    List.length (List.filter (String.ends_with ~suffix:"not answering") labels)
    = silent
    && List.length (List.filter (String.ends_with ~suffix:"Uploading 1") labels)
       = count - silent
  in
  let ok = wait_until ~timeout:20. current in
  say w "%d domains, %d silent: every row current after one status deadline: %s"
    count silent
    (if ok && Rt.now () -. started < status_deadline +. margin then "yes"
     else Printf.sprintf "NO (%.1f s)" (Rt.now () -. started))

(* §9 "Ids", "Grouped events", "Mount point", "Signals only on change". *)
let ids w =
  configure w ["stable"; "moving"];
  owner w "stable" ~status:{|{"ok":true,"mount":"/reported/stable dir"}|};
  owner w "moving" ~status:(busy "a_b.bin" 1);
  own w file_manager;
  start_tray w;
  ignore (shows w "moving — Uploading");
  let stable = (row w "stable").id and moving = (row w "moving").id in
  let file = (row w "    a__b.bin").id in
  let settled = Rt.now () in
  Rt.sleep ((2. *. poll_interval) +. 0.5);
  say w
    "two refreshes with the same status: %d LayoutUpdated, %d NewIcon, %d \
     NewToolTip"
    (List.length (signals ~since:settled w "LayoutUpdated"))
    (List.length (signals ~since:settled w "NewIcon"))
    (List.length (signals ~since:settled w "NewToolTip"));
  check w "and no id changed"
    ((row w "stable").id = stable && (row w "moving").id = moving);
  write (script w "moving" "status") {|{"ok":true}|};
  ignore (shows w "moving — Idle");
  check w "the changed row has another id" ((row w "moving").id <> moving);
  check w "the unchanged row kept its id" ((row w "stable").id = stable);
  click w moving;
  click w file;
  Rt.sleep 0.5;
  say w "clicks on the old ids of a changed and of a removed row: %d actions"
    (List.length (shown w));
  click w stable;
  ignore (wait_until (fun () -> shown w <> []));
  List.iter
    (fun (member, uri) -> say w "click on an unchanged row: %s %s" member uri)
    (shown w);
  locked w (fun () -> w.file_manager <- []);
  (match
     menu w "EventGroup"
       [
         Array
           ( "(isvu)",
             [
               Struct
                 [Int32 stable; String "clicked"; Variant (Int32 0); Uint32 0];
               Struct
                 [Int32 moving; String "clicked"; Variant (Int32 0); Uint32 0];
               Struct
                 [Int32 9999; String "clicked"; Variant (Int32 0); Uint32 0];
             ] );
       ]
   with
    | Ok [Array (_, errors)] ->
        say w "EventGroup answers the ids that name no row: %b"
          (List.sort compare errors = [Int32 moving; Int32 9999])
    | _ -> say w "EventGroup: ?");
  ignore (wait_until (fun () -> shown w <> []));
  List.iter
    (fun (member, uri) ->
      say w "the same click through EventGroup: %s %s" member uri)
    (shown w);
  let before = requests w "stable" "stats" in
  (match menu w "AboutToShowGroup" [Array ("i", [Int32 0; Int32 9999])] with
    | Ok [Array (_, _); Array (_, errors)] ->
        say w "AboutToShowGroup answers the ids that name no row: %b"
          (errors = [Int32 9999])
    | _ -> say w "AboutToShowGroup: ?");
  check w "AboutToShowGroup starts the stats fetch"
    (wait_until (fun () -> requests w "stable" "stats" = before + 1));
  write (script w "moving" "status") (busy "c.bin" 3);
  Rt.sleep (poll_interval +. status_deadline);
  say w "AboutToShowGroup marks the menu open: %d root updates while it is"
    (List.length
       (root_updates ~since:(Rt.now () -. poll_interval -. status_deadline) w));
  event w 0 "closed";
  (* Churn: no id is ever given to two different rows. *)
  let seen = Hashtbl.create 64 and reused = ref false in
  let observe () =
    let rec walk n =
      (match Hashtbl.find_opt seen n.id with
        | Some properties when properties <> n.properties -> reused := true
        | _ -> Hashtbl.replace seen n.id n.properties);
      List.iter walk n.children
    in
    List.iter walk (rows w)
  in
  for i = 1 to 4 do
    write
      (script w "moving" "status")
      (busy (Printf.sprintf "f%d.bin" (i mod 2)) i);
    Rt.sleep poll_interval;
    observe ()
  done;
  check w "over churning rows no id is seen on two different rows" (not !reused);
  check w "the revision increases" (revisions_increase w)

(* §9 "An open menu is not replaced", "Stats". *)
let open_menu w =
  configure w ["photos"];
  owner w "photos";
  write
    (script w "photos" "stats")
    {|{"ok":true,"self":{"server":{"hostname":"box","role":"owner","pid":7,"uptimeSeconds":3600}},"domains":[{"name":"photos","settings":{"versioning":true}}]}|};
  own w file_manager;
  start_tray w;
  ignore (shows w "photos — Idle");
  let stats () = row w "Stats" in
  say w "before any opening the Stats row holds: %s"
    (String.concat " | " (List.map label (stats ()).children));
  let stats_id = (stats ()).id and photos = (row w "photos").id in
  let opened = Rt.now () in
  ignore (menu w "AboutToShow" [Int32 0]);
  event w 0 "opened";
  check w "after the answers the rows are the model's"
    (wait_until (fun () -> List.length (stats ()).children > 1));
  say w "the Stats row holds: %s"
    (String.concat " | " (List.map label (stats ()).children));
  say w "announced against the Stats row, with the menu open: %b"
    (List.exists
       (fun s ->
         match s.arguments with [_; Int32 p] -> p = stats_id | _ -> false)
       (signals ~since:opened w "LayoutUpdated"));
  say w "one opening announced twice: %d stats requests"
    (requests w "photos" "stats");
  for i = 1 to 3 do
    write (script w "photos" "status") (busy "f.bin" i);
    Rt.sleep poll_interval
  done;
  say w "content changing at every poll, menu open: %d root updates"
    (List.length (root_updates ~since:opened w));
  say w "the row list is still the one fetched at the opening: %s"
    (label (row w "photos"));
  click w photos;
  check w "a row fetched at the opening is still clickable"
    (wait_until (fun () -> shown w <> []));
  let before = Rt.now () in
  event w stats_id "closed";
  Rt.sleep 0.5;
  say w "after closed for the Stats row: %d root updates"
    (List.length (root_updates ~since:before w));
  event w 0 "closed";
  check w "after closed for the root the next layout is announced"
    (wait_until ~timeout:1. (fun () -> root_updates ~since:before w <> []));
  say w "and reads: %s" (label (row w "photos"));
  check w "the stats rows are still there after the redraw"
    (List.length (stats ()).children > 1);
  Rt.sleep (2. *. poll_interval);
  configure w ["added"; "photos"];
  ignore (shows w "added");
  check w "and after two polls and a domain added above"
    (List.length (stats ()).children > 1);
  check w "the revision increases" (revisions_increase w)

(* §9 "A host that reports no close". *)
let no_close w =
  configure w ["photos"];
  owner w "photos";
  start_tray w;
  ignore (shows w "photos — Idle");
  ignore (menu w "AboutToShow" [Int32 0]);
  let opened = Rt.now () in
  write (script w "photos" "status") (busy "one.bin" 1);
  Rt.sleep (poll_interval +. status_deadline);
  say w "held while open: %s" (label (row w "photos"));
  (match menu w "AboutToShow" [Int32 0] with
    | Ok [Bool changed] ->
        say w "the next opening of the root installs it at once: %b, %s" changed
          (label (row w "photos"))
    | _ -> say w "AboutToShow: ?");
  let reopened = Rt.now () in
  write (script w "photos" "status") {|{"ok":true}|};
  Rt.sleep (poll_interval +. status_deadline);
  say w "held again: %s" (label (row w "photos"));
  let current () = label (row w "photos") = "photos — Idle" in
  ignore (wait_until ~timeout:(Layout.menu_open_bound +. 5.) current);
  let waited = Rt.now () -. reopened in
  say w "with no close ever sent, current within MENU_OPEN_BOUND: %s"
    (if current () && waited <= Layout.menu_open_bound +. margin then "yes"
     else Printf.sprintf "NO (%.1f s)" waited);
  ignore opened;
  check w "the revision increases" (revisions_increase w)

(* §9 "Stats" with nobody answering, "Hold switch", "Mount point" with a
   silent owner, "Reveal" with no file manager. *)
let hold w =
  configure w ["refusing"; "willing"; "quiet"];
  owner w "refusing"
    ~status:
      {|{"ok":true,"mount":"/reported/refusing","downloading":[{"name":"a b.txt","rel":"sub dir/a b.txt"}]}|};
  write
    (script w "refusing" "pause")
    {|{"ok":false,"code":"internal","error":"the disk is full"}|};
  owner w "willing";
  write (script w "willing" "pause") {|{"ok":true,"paused":true}|};
  owner ~mode:"silent" w "quiet";
  start_tray w;
  ignore (shows w "willing — Idle");
  let switch () =
    List.assoc_opt "toggle-state" (row w "Hold changes").properties
  in
  let clicked = Rt.now () in
  click w (row w "Hold changes").id;
  check w "with one owner silent the others are asked"
    (wait_until (fun () ->
         requests w "refusing" "pause" = 1 && requests w "willing" "pause" = 1));
  let logged () =
    Text.contains (read (path w "tray.err")) "refusing"
    && Text.contains (read (path w "tray.err")) "the disk is full"
  in
  check w "the refusal is logged with the domain and the reason"
    (wait_until ~timeout:10. logged);
  let waited = Rt.now () -. clicked in
  say w "and the click costs one deadline: %s"
    (if waited < 5. +. margin then "yes"
     else Printf.sprintf "NO (%.1f s)" waited);
  Rt.sleep status_deadline;
  say w "the checkmark is what the owners report: %s"
    (match switch () with
      | Some (Int32 0) -> "unchecked"
      | Some (Int32 1) -> "checked"
      | _ -> "?");
  click w (row w "refusing").id;
  click w (row w "quiet").id;
  click w (row w "    a b.txt").id;
  check w "with no file manager the helper is run"
    (wait_until (fun () -> List.length (lines (path w "xdg-open.log")) = 3));
  List.iter (say w "xdg-open %s")
    (List.sort compare (lines (path w "xdg-open.log")));
  own w file_manager;
  click w (row w "refusing").id;
  click w (row w "quiet").id;
  click w (row w "    a b.txt").id;
  ignore (wait_until (fun () -> List.length (shown w) = 3));
  List.iter
    (fun (member, uri) -> say w "%s %s" member uri)
    (List.sort compare (shown w));
  say w "the helper was not run again: %d lines"
    (List.length (lines (path w "xdg-open.log")))

let nobody w =
  configure w ["quiet"];
  owner ~mode:"silent" w "quiet";
  start_tray w;
  ignore (shows w "quiet — not answering");
  ignore (menu w "AboutToShow" [Int32 0]);
  Rt.sleep (4. +. margin);
  say w "with no owner answering the Stats row holds: %s"
    (String.concat " | " (List.map label (row w "Stats").children));
  say w "icon %s, switch enabled %s"
    (match
       call_at w ~path:"/StatusNotifierItem"
         ~interface:"org.freedesktop.DBus.Properties" "Get"
         [String "org.kde.StatusNotifierItem"; String "IconName"]
     with
      | Ok [Variant (String s)] -> s
      | _ -> "?")
    (match List.assoc_opt "enabled" (row w "Hold changes").properties with
      | Some (Bool b) -> string_of_bool b
      | _ -> "?")

(* §9 "Panel lifecycle". *)
let panel w =
  configure w ["photos"];
  owner w "photos";
  start_tray w;
  ignore (shows w "photos — Idle");
  say w "started before the watcher: %d registrations"
    (List.length (locked w (fun () -> w.registrations)));
  own w watcher;
  check w "registered when the watcher appears"
    (wait_until (fun () -> locked w (fun () -> w.registrations) = [item w]));
  let other = Bus.connect w.address in
  Rt.spawn ~name:"second watcher" (fun () -> Bus.serve other (host_handler w));
  let before = Rt.now () in
  ignore (bus_call w "ReleaseName" [String watcher]);
  own ~connection:other w watcher;
  check w "registered again when the watcher's name changes owner"
    (wait_until (fun () ->
         List.length (locked w (fun () -> w.registrations)) = 2));
  check w "then NewIcon and NewToolTip on both interfaces"
    (wait_until (fun () ->
         List.length (signals ~since:before w "NewIcon") = 2
         && List.length (signals ~since:before w "NewToolTip") = 2));
  Rt.sleep (2. *. poll_interval);
  let warnings =
    List.length
      (List.filter
         (fun l -> Text.contains l "no StatusNotifier host is running")
         (lines (path w "tray.err")))
  in
  say w "with no host at start it runs and warns once: %d" warnings

(* §9 "Session", "Quit". *)
let session w =
  configure w ["photos"];
  owner w "photos";
  let pid = run_tray ~address:false w in
  say w "no bus address and no session socket: exit %s"
    (match exit_status pid with Some c -> string_of_int c | None -> "none");
  say w "%s" (String.trim (read (path w "tray.err")));
  say w "no bus was started for it: %b"
    ( bus_call w "ListNames" [] |> function
      | Ok [Array (_, names)] ->
          not
            (List.exists
               (function
                 | Dbus.String n ->
                     String.starts_with ~prefix:"org.kde.StatusNotifierItem" n
                 | _ -> false)
               names)
      | _ -> false );
  w.tray <- run_tray ~address:false ~runtime:true w;
  check w "with the session socket present it uses it"
    (wait_until (fun () -> has_owner w (item w)));
  let second = run_tray w in
  let started = Rt.now () in
  say w "a second tray: exit %s at once: %b"
    (match exit_status second with Some c -> string_of_int c | None -> "none")
    (Rt.now () -. started < 2.);
  say w "%s" (String.trim (read (path w "tray.out")));
  say w "items on the bus: %d"
    (match bus_call w "ListNames" [] with
      | Ok [Array (_, names)] ->
          List.length
            (List.filter
               (function
                 | Dbus.String n ->
                     String.starts_with ~prefix:"org.kde.StatusNotifierItem" n
                 | _ -> false)
               names)
      | _ -> -1);
  let bad = run_tray ~arguments:["--nope"] w in
  say w "a command-line error: exit %s"
    (match exit_status bad with Some c -> string_of_int c | None -> "none");
  ignore (shows w "photos — Idle");
  click w (row w "Quit tsync tray").id;
  say w "after Quit: exit %s"
    (match exit_status w.tray with Some c -> string_of_int c | None -> "none");
  say w "and the owner still answers: %b"
    (Tsync_ipc.Ipc.ask ~deadline:2. (socket w "photos")
       (`Assoc [("action", `String "ping")])
    <> None);
  w.tray <- run_tray w;
  ignore (wait_until (fun () -> has_owner w (item w)));
  Unix.kill w.daemon Sys.sigterm;
  say w "when the bus closes: exit %s"
    (match exit_status w.tray with Some c -> string_of_int c | None -> "none")

(* §9 "Config". *)
let config w =
  owner w "photos";
  owner w "music";
  start_tray w;
  let header () = shows w "tsync — No domains configured" in
  let repaired names =
    let started = Rt.now () in
    configure w names;
    let ok = shows w (List.hd names ^ " — Idle") in
    ok && Rt.now () -. started <= (2. *. poll_interval) +. margin
  in
  check w "with no config it runs and shows no domains" (header ());
  check w "the domains appear after it is written" (repaired ["photos"]);
  write (path w "c/tsync/config.json") "{not json";
  check w "a config that is not JSON shows no domains" (header ());
  check w "repaired within two poll intervals" (repaired ["photos"]);
  write
    (path w "c/tsync/config.json")
    {|{"domains":[{"name":"photos"}],"bogus":1}|};
  check w "a config that fails validation shows no domains" (header ());
  check w "repaired within two poll intervals" (repaired ["photos"]);
  configure w ["photos"; "music"];
  configure w ["music"];
  Rt.sleep ((2. *. poll_interval) +. margin);
  say w "rewritten twice in quick succession: %s"
    (String.concat " | "
       (List.filter (fun l -> Text.contains l " — ") (labels w)));
  say w "one warning per distinct reason: %d"
    (List.length
       (List.filter
          (fun l -> Text.contains l "tray: no domains")
          (lines (path w "tray.err"))))

(* The scenarios that measure a bound run first, one at a time: beside a
   dozen trays starting at once they would measure the machine. *)
let measured =
  [
    ("the bus is served while owners are silent", served);
    ("one silent owner of 2", deadline ~silent:1 2);
    ("one silent owner of 20", deadline ~silent:1 20);
    ("20 silent owners of 20", deadline ~silent:20 20);
  ]

let side_by_side =
  [
    ("every call is answered", calls);
    ("ids, grouped events, signals only on change", ids);
    ("an open menu is not replaced; stats", open_menu);
    ("a host that reports no close", no_close);
    ("hold switch, mount point, reveal", hold);
    ("nobody answering", nobody);
    ("panel lifecycle", panel);
    ("session and quit", session);
    ("config", config);
  ]

let () =
  Fs.mkdir_p ~perm:0o700 root;
  let only = if Array.length Sys.argv > 3 then Some Sys.argv.(3) else None in
  let selected =
    List.filter (fun (title, _) ->
        match only with None -> true | Some o -> Text.contains title o)
  in
  let run (title, scenario) =
    let w = world () in
    (try scenario w with e -> say w "FAILED: %s" (Printexc.to_string e));
    (title, Buffer.contents w.out)
  in
  let results =
    Rt.run_sync (fun () ->
        let first = List.map run (selected measured) in
        first
        @ Rt.map_concurrently
            (fun (delay, scenario) ->
              Rt.sleep delay;
              run scenario)
            (List.mapi
               (fun i scenario -> (0.5 *. float_of_int i, scenario))
               (selected side_by_side)))
  in
  List.iter (fun pid -> try Unix.kill pid Sys.sigkill with _ -> ()) !children;
  List.iter
    (fun (title, text) -> Printf.printf "== %s\n%s\n" title text)
    results;
  if results = [] then failwith "no scenario ran";
  Printf.printf "%d scenarios\n" (List.length results);
  if only = None then Fs.rm_rf root
