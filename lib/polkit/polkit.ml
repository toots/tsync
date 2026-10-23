open Tsync_core
open Tsync_dbus_dl

let authority = "org.freedesktop.PolicyKit1"
let action = "org.feverdreamtv.tsync.verify-user"
let action_file = "/usr/share/polkit-1/actions/org.feverdreamtv.tsync.policy"

(* A person is answering a dialog. *)
let patience = 300.
let allow_user_interaction = 1

type answer = [ `Authorized | `Dismissed | `Refused | `No_agent ]

let unreachable fmt = Fail.raise_ Unreachable ("polkit: " ^^ fmt)

(* ponytail: a third reply loop beside logind's and the Secret Service's; one in Tsync_dbus once the ownership review asks. *)
let rec await bus serial ~deadline =
  let rec popped () =
    match Dbus.pop bus with
      | Some m
        when Dbus.reply_serial m = serial
             && (Dbus.kind m = Method_return || Dbus.kind m = Error_reply) ->
          Some m
      | Some _ -> popped ()
      | None -> None
  in
  match popped () with
    | Some m -> m
    | None -> (
        if not (Dbus.read_write bus) then unreachable "the system bus closed";
        match popped () with
          | Some m -> m
          | None ->
              let left = deadline -. Rt.now () in
              if left <= 0. then unreachable "no answer within %.0f s" patience;
              (try
                 Rt.wait_readable
                   ~timeout:
                     (if Dbus.has_output bus then min left 0.02 else left)
                   (Dbus.descriptor bus)
               with Rt.Timeout -> ());
              await bus serial ~deadline)

let dismissed details =
  List.exists
    (function
      | Dbus.Dict_entry (String "polkit.dismissed", String "true") -> true
      | _ -> false)
    details

let check ~address =
  let bus =
    try Dbus.connect address with Dbus.Error reason -> unreachable "%s" reason
  in
  Fun.protect ~finally:(fun () -> Dbus.close bus) @@ fun () ->
  (* polkit resolves the bus name to this process and its session. *)
  let subject =
    Dbus.Struct
      [
        String "system-bus-name";
        Array
          ( "{sv}",
            [
              Dict_entry (String "name", Variant (String (Dbus.unique_name bus)));
            ] );
      ]
  in
  let serial =
    try
      Dbus.send bus
        (Dbus.method_call ~destination:authority
           ~path:"/org/freedesktop/PolicyKit1/Authority"
           ~interface:"org.freedesktop.PolicyKit1.Authority"
           ~member:"CheckAuthorization"
           [
             subject;
             String action;
             Array ("{ss}", []);
             Uint32 allow_user_interaction;
             String "";
           ])
    with Dbus.Error reason -> unreachable "%s" reason
  in
  let reply = await bus serial ~deadline:(Rt.now () +. patience) in
  match (Dbus.kind reply, Dbus.body reply) with
    | Error_reply, _ -> unreachable "%s" (Dbus.error_name reply)
    | _, [Struct [Bool true; _; _]] -> `Authorized
    (* Still a challenge after interaction was allowed: no agent showed one. *)
    | _, [Struct [Bool false; Bool true; _]] -> `No_agent
    | _, [Struct [Bool false; Bool false; Array (_, details)]] ->
        if dismissed details then `Dismissed else `Refused
    | _ -> Fail.raise_ Corrupt "polkit: an answer of an unknown shape"

let register () =
  if Dbus.available () && Sys.file_exists action_file then
    Tsync_owner.Verifier.register
      {
        name = "polkit";
        verify =
          (fun ~reason:_ ->
            match check ~address:(Dbus.system_address ()) with
              | `Authorized -> Ok ()
              | `Dismissed -> Error "the dialog was dismissed"
              | `Refused -> Error "not authenticated"
              | `No_agent -> unreachable "no agent in this session");
      }
