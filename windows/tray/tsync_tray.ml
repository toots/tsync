(* The Windows tray (cloud-files §15): Tray_core over a notification-area icon.
   [start] runs the interface thread in C, [set_menu] hands it a snapshot it
   draws without waiting on anything, and [next] returns what the user did. *)

open Cmdliner
open Tsync_core
open Tsync_menu
open Tsync_tray_core
module M = Menu_model

(** One menu row as C reads it: [id] is the key of a submenu row, else what a
    click on it reports; [checked] is -1 without a checkmark. *)
type row = {
  label : string;
  id : int;
  separator : bool;
  enabled : bool;
  checked : int;
  children : row array;
}
[@@warning "-69"]

external single : unit -> bool = "tsync_wtray_single"
external start : unit -> unit = "tsync_wtray_start"
external next : unit -> int * int = "tsync_wtray_next"
external set_menu : row array -> unit = "tsync_wtray_set_menu"
external set_icon : int -> string -> unit = "tsync_wtray_set_icon"
external notify : string -> string -> unit = "tsync_wtray_notify"
external copy : string -> bool = "tsync_wtray_copy"
external show : string -> bool -> unit = "tsync_wtray_show"
external ask : string -> string -> string option = "tsync_wtray_ask"

let stats_key = 1
let codes_key = 2

(* ponytail: ids cycle through a fixed table, so a click on a menu left open
   for thousands of rows' worth of refreshes runs a newer row's action. *)
let id_count = 30000

type t = {
  lock : Mutex.t;
  mutable entries : M.entry list;
  mutable stats : M.entry list;
  mutable codes : M.entry list;
  actions : M.action array;
  mutable next_id : int;
}

let tray =
  {
    lock = Mutex.create ();
    entries = [];
    stats = M.stats_placeholder;
    codes = M.codes_placeholder;
    actions = Array.make id_count M.Nothing;
    next_id = 0;
  }

(* A Win32 menu reads [&] as the mnemonic marker. *)
let label (item : M.item) =
  String.make (4 * item.indent) ' '
  ^ String.concat "&&" (String.split_on_char '&' item.label)

let separator =
  {
    label = "";
    id = 0;
    separator = true;
    enabled = false;
    checked = -1;
    children = [||];
  }

let rec rows entries = Array.of_list (List.map row entries)

and row = function
  | M.Separator -> separator
  | Item item ->
      let children, id =
        match item.action with
          | Show_stats when item.submenu -> (rows tray.stats, stats_key)
          | Show_codes when item.submenu -> (rows tray.codes, codes_key)
          | action ->
              let id = tray.next_id in
              tray.actions.(id) <- action;
              tray.next_id <- (id + 1) mod id_count;
              ([||], id)
      in
      {
        label = label item;
        id;
        separator = false;
        enabled = item.enabled;
        checked =
          (match item.checked with None -> -1 | Some c -> Bool.to_int c);
        children;
      }

let redraw () = Mutex.protect tray.lock (fun () -> set_menu (rows tray.entries))

let icon_state = function
  | "tsync-sync-symbolic" -> 1
  | "tsync-paused-symbolic" -> 2
  | "tsync-error-symbolic" -> 3
  | _ -> 0

let platform =
  {
    Tray_core.menu =
      (fun (menu : M.t) ->
        Mutex.protect tray.lock (fun () -> tray.entries <- menu.entries);
        redraw ();
        set_icon (icon_state menu.icon) menu.tooltip);
    children =
      (fun action entries ->
        Mutex.protect tray.lock (fun () ->
            match action with
              | Show_stats -> tray.stats <- entries
              | Show_codes -> tray.codes <- entries
              | _ -> ());
        redraw ());
    marks = ignore;
    notify;
    copy =
      (fun code ->
        if copy code then Ok () else Error "the clipboard did not take it");
    show = (fun ~folder path -> show path folder);
    ask_secret = (fun ~title prompt -> ask title prompt);
    can_ask = (fun () -> Ok ());
    code_domains = Fun.id;
  }

let rec events core =
  match next () with
    | 0, _ ->
        Tray_core.opened core;
        events core
    | 1, id ->
        let action = Mutex.protect tray.lock (fun () -> tray.actions.(id)) in
        Rt.spawn ~name:"tray action" (fun () ->
            Tray_core.run_action core action);
        events core
    | _ -> ignore (Rt.Promise.try_resolve (Tray_core.finished core) 0)

let run () =
  if not (single ()) then 0
  else (
    Log.debug "tray: starting";
    let core = Tray_core.create ~quit:"Quit tsync tray" platform in
    start ();
    Rt.spawn ~name:"tray events" (fun () -> events core);
    Rt.spawn ~name:"tray poll" (fun () -> Tray_core.poll core);
    Rt.Promise.await (Tray_core.finished core))

(* A windowed program's warnings go to tray.log beside the service log. *)
let log_to_file () =
  match Tsync_config.Paths.service_log () with
    | Some service_log when not (Unix.isatty Unix.stderr) ->
        let file = Filename.concat (Filename.dirname service_log) "tray.log" in
        Fs.mkdir_p ~durable:false (Filename.dirname file);
        let fd = Fs.unix_openfile file [O_WRONLY; O_APPEND; O_CREAT] 0o644 in
        Fs.with_fd fd (fun fd -> Unix.dup2 ~cloexec:false fd Unix.stderr)
    | _ -> ()

let main verbose =
  Fs.attach_missing_handles ();
  log_to_file ();
  Atomic.set Log.min_level (if verbose then Log.Debug else Log.Warn);
  Atomic.set Log.sink Log.stderr_sink;
  Rt.run_sync run

let verbose = Arg.(value & flag & info ["v"; "verbose"] ~doc:"Log debug lines.")

let () =
  let info =
    Cmd.info "tsync-tray" ~version:"%%VERSION%%"
      ~doc:"Show the state of tsync's domains in the notification area."
  in
  match Cmd.eval_value (Cmd.v info Term.(const main $ verbose)) with
    | Ok (`Ok code) -> exit code
    | Ok (`Help | `Version) -> exit 0
    | Error _ -> exit 1
