open Tsync_core
open Tsync_dbus

type t = {
  connection : Dbus.t;
  lock : Mutex.t;
  replies : (int, (Dbus.message, exn) result -> bool) Hashtbl.t;
}

let connect address =
  {
    connection = Dbus.connect address;
    lock = Mutex.create ();
    replies = Hashtbl.create 16;
  }

let locked t f = Mutex.protect t.lock f

let send t message =
  locked t (fun () ->
      ignore (Dbus.send t.connection message);
      ignore (Dbus.read_write t.connection))

let call t ~timeout ~destination ~path ~interface ~member arguments =
  let message =
    Dbus.method_call ~destination ~path ~interface ~member arguments
  in
  let serial = ref 0 in
  let forget () = locked t (fun () -> Hashtbl.remove t.replies !serial) in
  match
    Rt.with_timeout timeout (fun () ->
        Rt.suspend (fun resolve ->
            locked t (fun () ->
                serial := Dbus.send t.connection message;
                Hashtbl.replace t.replies !serial resolve;
                ignore (Dbus.read_write t.connection));
            forget))
  with
    | reply when Dbus.kind reply = Dbus.Error_reply ->
        Error (Dbus.error_name reply)
    | reply -> Ok (Dbus.body reply)
    | exception Rt.Timeout -> Error "timeout"

(* How long queued output waits for the socket before another attempt. *)
let output_retry = 0.02

let serve t handle =
  let descriptor = Dbus.descriptor t.connection in
  let rec loop () =
    let waiting = locked t (fun () -> Dbus.has_output t.connection) in
    (try
       Rt.wait_readable
         ~timeout:(if waiting then output_retry else 1.)
         descriptor
     with Rt.Timeout -> ());
    let connected, messages =
      locked t (fun () ->
          let connected = Dbus.read_write t.connection in
          let rec drain acc =
            match Dbus.pop t.connection with
              | Some m -> drain (m :: acc)
              | None -> List.rev acc
          in
          (connected, drain []))
    in
    List.iter
      (fun message ->
        match Dbus.kind message with
          | Method_return | Error_reply ->
              let waiter =
                locked t (fun () ->
                    let serial = Dbus.reply_serial message in
                    let w = Hashtbl.find_opt t.replies serial in
                    Hashtbl.remove t.replies serial;
                    w)
              in
              Option.iter (fun resolve -> ignore (resolve (Ok message))) waiter
          | Method_call | Signal -> (
              try handle message
              with e ->
                Log.warn "tray: a bus message failed: %s" (Printexc.to_string e)
              ))
      messages;
    if connected then loop ()
  in
  loop ()
