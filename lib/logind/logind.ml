open Tsync_core
open Tsync_dbus_dl

let login1 = "org.freedesktop.login1"
let session_interface = "org.freedesktop.login1.Session"
let manager_interface = "org.freedesktop.login1.Manager"
let timeout = 5.
let retry = 60.

exception Broken of string

let rule ?arg0 ~interface ~member () =
  Printf.sprintf "type='signal',sender='%s',interface='%s',member='%s'%s" login1
    interface member
    (match arg0 with Some a -> Printf.sprintf ",arg0='%s'" a | None -> "")

(* A read can queue several messages at once: they are popped before the
   socket is waited on again. *)
let rec next bus ~deadline =
  match Dbus.pop bus with
    | Some m -> Some m
    | None -> (
        if not (Dbus.read_write bus) then raise (Broken "the system bus closed");
        match Dbus.pop bus with
          | Some m -> Some m
          | None ->
              let left = deadline -. Rt.now () in
              if left <= 0. then None
              else (
                (try
                   Rt.wait_readable
                     ~timeout:
                       (if Dbus.has_output bus then Float.min left 0.02
                        else left)
                     (Dbus.descriptor bus)
                 with Rt.Timeout -> ());
                next bus ~deadline))

(* Signals that arrive while a reply is awaited are kept for the loop. *)
let call bus ~pending ~destination ~path ~interface ~member arguments =
  let serial =
    try
      Dbus.send bus
        (Dbus.method_call ~destination ~path ~interface ~member arguments)
    with Dbus.Error reason -> raise (Broken reason)
  in
  let deadline = Rt.now () +. timeout in
  let rec reply () =
    match next bus ~deadline with
      | Some m when Dbus.reply_serial m = serial -> (
          match Dbus.kind m with Error_reply -> None | _ -> Some (Dbus.body m))
      | Some m ->
          Queue.push m pending;
          reply ()
      | None -> raise (Broken "no answer from logind")
  in
  reply ()

(* A session belongs to this user when its [User] property names our uid. *)
let ours bus ~pending path =
  match
    call bus ~pending ~destination:login1 ~path
      ~interface:"org.freedesktop.DBus.Properties" ~member:"Get"
      [Dbus.String session_interface; Dbus.String "User"]
  with
    | Some [Dbus.Variant (Dbus.Struct (Dbus.Uint32 uid :: _))] ->
        uid = Unix.getuid ()
    | _ -> false

(* security-model §10.6: a desktop's own locker (Plasma's, GNOME's) sets the
   session's [LockedHint] without the [Lock] that [loginctl lock-session] sends. *)
let locked_hint = function
  | Dbus.String i :: Dbus.Array (_, changed) :: _ when i = session_interface ->
      List.mem
        (Dbus.Dict_entry (String "LockedHint", Variant (Bool true)))
        changed
  | _ -> false

let locks bus ~pending m =
  Dbus.kind m = Signal
  &&
    match (Dbus.interface m, Dbus.member m, Dbus.body m) with
    | i, "PrepareForSleep", [Dbus.Bool true] when i = manager_interface -> true
    | i, "Lock", _ when i = session_interface -> ours bus ~pending (Dbus.path m)
    | "org.freedesktop.DBus.Properties", "PropertiesChanged", body
      when locked_hint body ->
        ours bus ~pending (Dbus.path m)
    | _ -> false

let serve ~on_lock =
  let bus =
    try Dbus.connect (Dbus.system_address ())
    with Dbus.Error reason -> raise (Broken reason)
  in
  Fun.protect ~finally:(fun () -> Dbus.close bus) @@ fun () ->
  let pending = Queue.create () in
  List.iter
    (fun rule ->
      ignore
        (call bus ~pending ~destination:"org.freedesktop.DBus"
           ~path:"/org/freedesktop/DBus" ~interface:"org.freedesktop.DBus"
           ~member:"AddMatch" [Dbus.String rule]))
    [
      rule ~interface:session_interface ~member:"Lock" ();
      rule ~interface:manager_interface ~member:"PrepareForSleep" ();
      rule ~arg0:session_interface ~interface:"org.freedesktop.DBus.Properties"
        ~member:"PropertiesChanged" ();
    ];
  let rec loop () =
    let m =
      match Queue.take_opt pending with
        | Some m -> Some m
        | None -> next bus ~deadline:(Rt.now () +. 3600.)
    in
    Option.iter (fun m -> if locks bus ~pending m then on_lock ()) m;
    loop ()
  in
  loop ()

let watch ~on_lock =
  if Dbus.available () then
    Rt.spawn ~name:"logind" (fun () ->
        let rec run () =
          match serve ~on_lock with
            | () -> ()
            | exception Broken reason ->
                Log.info "logind: %s; watching again in %.0f s" reason retry;
                Stop.sleep retry;
                run ()
            | exception (Stop.Stopping as e) -> raise e
            | exception e ->
                Log.warn "logind: %s; watching again in %.0f s"
                  (Printexc.to_string e) retry;
                Stop.sleep retry;
                run ()
        in
        try run () with Stop.Stopping -> ())
