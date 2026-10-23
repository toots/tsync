(* polkit's authority on the bus at argv.(1): it answers each CheckAuthorization
   with the next of authorized, dismissed, refused and no agent, and appends what
   it was asked to the file argv.(2). *)

open Tsync_core
open Tsync_dbus
open Tsync_tray_lib

let answers =
  [|
    (true, false, []);
    (false, false, [("polkit.dismissed", "true")]);
    (false, false, []);
    (false, true, [("polkit.result", "auth_self")]);
  |]

let asked = ref 0

let record line =
  Out_channel.with_open_gen [Open_append; Open_creat] 0o600 Sys.argv.(2)
    (fun oc -> output_string oc (line ^ "\n"))

let answer message =
  match (Dbus.member message, Dbus.body message) with
    | ( "CheckAuthorization",
        [
          Struct [String kind; Array (_, subject)];
          String action;
          Array _;
          Uint32 flags;
          String _;
        ] ) ->
        let name =
          List.find_map
            (function
              | Dbus.Dict_entry (String "name", Variant (String n)) -> Some n
              | _ -> None)
            subject
        in
        record
          (Printf.sprintf "subject %s, a bus name %b, action %s, flags %d" kind
             (match name with
               | Some n -> String.length n > 1 && n.[0] = ':'
               | None -> false)
             action flags);
        let authorized, challenge, details = answers.(!asked mod 4) in
        incr asked;
        Ok
          [
            Dbus.Struct
              [
                Bool authorized;
                Bool challenge;
                Array
                  ( "{ss}",
                    List.map
                      (fun (k, v) -> Dbus.Dict_entry (String k, String v))
                      details );
              ];
          ]
    | member, _ -> Error member

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
           [String "org.freedesktop.PolicyKit1"; Uint32 4]
       with
        | Ok [Uint32 1] -> print_endline "ready"
        | _ -> exit 1);
      let rec wait () =
        Rt.sleep 3600.;
        wait ()
      in
      wait ())
