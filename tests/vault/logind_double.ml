(* logind on the bus at argv.(1): two sessions, [mine] of this uid and [other]
   of another, and one signal emitted per line of standard input ([lock mine],
   [lock other], [sleep true], [sleep false]). *)

open Tsync_core
open Tsync_dbus
open Tsync_tray_lib

let session name = "/org/freedesktop/login1/session/" ^ name

let user path =
  if path = session "mine" then Some (Unix.getuid ())
  else if path = session "other" then Some (Unix.getuid () + 1)
  else None

let answer message =
  match (Dbus.member message, Dbus.body message, user (Dbus.path message)) with
    | "Get", [String "org.freedesktop.login1.Session"; String "User"], Some uid
      ->
        Ok
          [
            Dbus.Variant
              (Struct [Uint32 uid; Object_path "/org/freedesktop/login1/user/1"]);
          ]
    | member, _, _ -> Error member

let signal = function
  | ["lock"; name] ->
      Some
        (Dbus.signal ~path:(session name)
           ~interface:"org.freedesktop.login1.Session" ~member:"Lock" [])
  | ["sleep"; flag] ->
      Some
        (Dbus.signal ~path:"/org/freedesktop/login1"
           ~interface:"org.freedesktop.login1.Manager" ~member:"PrepareForSleep"
           [Bool (flag = "true")])
  | _ -> None

let () =
  Rt.run_sync (fun () ->
      let bus = Bus.connect Sys.argv.(1) in
      Rt.spawn ~name:"double" (fun () ->
          Bus.serve bus (fun message ->
              if Dbus.kind message = Method_call then
                Bus.send bus
                  (match answer message with
                    | Ok body -> Dbus.method_return message body
                    | Error member ->
                        Dbus.error_reply message
                          ~name:"org.freedesktop.DBus.Error.UnknownMethod"
                          member)));
      (match
         Bus.call bus ~timeout:5. ~destination:"org.freedesktop.DBus"
           ~path:"/org/freedesktop/DBus" ~interface:"org.freedesktop.DBus"
           ~member:"RequestName"
           [String "org.freedesktop.login1"; Uint32 4]
       with
        | Ok [Uint32 1] -> print_endline "ready"
        | _ -> exit 1);
      (* Lines split here: a buffered channel would hide the lines it read
         ahead from the readiness of the descriptor. *)
      let chunk = Bytes.create 4096 in
      let rec read pending =
        match String.index_opt pending '\n' with
          | Some i ->
              Option.iter (Bus.send bus)
                (signal (String.split_on_char ' ' (String.sub pending 0 i)));
              read (String.sub pending (i + 1) (String.length pending - i - 1))
          | None -> (
              Rt.wait_readable Unix.stdin;
              match Unix.read Unix.stdin chunk 0 (Bytes.length chunk) with
                | 0 -> exit 0
                | n -> read (pending ^ Bytes.sub_string chunk 0 n))
      in
      read "")
