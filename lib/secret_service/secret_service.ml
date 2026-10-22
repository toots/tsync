open Tsync_core
open Tsync_dbus_dl

let service = "org.freedesktop.secrets"
let service_path = "/org/freedesktop/secrets"
let default_collection = "/org/freedesktop/secrets/aliases/default"
let service_interface = "org.freedesktop.Secret.Service"
let item_interface = "org.freedesktop.Secret.Item"
let timeout = 5.

type connection = { bus : Dbus.t; session : string }

let fail fmt = Fail.raise_ Refused ("the Secret Service: " ^^ fmt)

(* Reads until the reply to [serial] arrives; other messages are dropped. *)
let await bus serial ~deadline =
  let rec next () =
    if not (Dbus.read_write bus) then fail "the session bus closed";
    let rec reply () =
      match Dbus.pop bus with
        | None -> None
        | Some m
          when Dbus.reply_serial m = serial
               && (Dbus.kind m = Method_return || Dbus.kind m = Error_reply) ->
            Some m
        | Some _ -> reply ()
    in
    match reply () with
      | Some m -> m
      | None ->
          let left = deadline -. Rt.now () in
          if left <= 0. then fail "no answer within %.0f s" timeout;
          (try
             Rt.wait_readable
               ~timeout:(if Dbus.has_output bus then min left 0.02 else left)
               (Dbus.descriptor bus)
           with Rt.Timeout -> ());
          next ()
  in
  next ()

let call bus ~path ~interface ~member arguments =
  let deadline = Rt.now () +. timeout in
  let message =
    Dbus.method_call ~destination:service ~path ~interface ~member arguments
  in
  let reply = await bus (Dbus.send bus message) ~deadline in
  match (Dbus.kind reply, Dbus.body reply) with
    | Error_reply, Dbus.String text :: _ ->
        fail "%s: %s" (Dbus.error_name reply) text
    | Error_reply, _ -> fail "%s" (Dbus.error_name reply)
    | _, body -> body

(* security-model §10.6: a plain session; the bus is local to the user. *)
let open_connection address =
  let bus = Dbus.connect address in
  match
    call bus ~path:service_path ~interface:service_interface
      ~member:"OpenSession"
      [String "plain"; Variant (String "")]
  with
    | [_; Object_path session] -> { bus; session }
    | _ -> fail "OpenSession answered an unexpected reply"

(* security-model §10.6: an owner started by a system unit has neither
   variable, and finds the user's bus where systemd puts it once they log in. *)
let address () =
  match Dbus.session_address () with
    | Some address -> address
    | None -> (
        let socket = Printf.sprintf "/run/user/%d/bus" (Unix.getuid ()) in
        match (Sys.getenv_opt "XDG_RUNTIME_DIR", Unix.stat socket) with
          | (None | Some ""), { st_kind = S_SOCK; _ } -> "unix:path=" ^ socket
          | _ | (exception Unix.Unix_error _) -> fail "no session bus")

let lock = Rt.Fmutex.create ()
let current = ref None

(* One connection per process, opened again after any failure. *)
let with_connection f =
  Rt.Fmutex.with_lock lock (fun () ->
      let c =
        match !current with
          | Some c -> c
          | None ->
              let c =
                try open_connection (address ())
                with Dbus.Error reason -> fail "%s" reason
              in
              current := Some c;
              c
      in
      try f c
      with e ->
        current := None;
        raise e)

let no_prompt = function
  | Dbus.Object_path "/" -> ()
  | _ -> fail "the call asks for a prompt, which tsync never shows"

let attributes pairs =
  Dbus.Array
    ("{ss}", List.map (fun (k, v) -> Dbus.Dict_entry (String k, String v)) pairs)

let entry name = [("application", "tsync-vault"); ("domain", name)]

let search c name =
  match
    call c.bus ~path:service_path ~interface:service_interface
      ~member:"SearchItems"
      [attributes (entry name)]
  with
    | [Array (_, unlocked); Array (_, locked)] ->
        let paths =
          List.filter_map (function Dbus.Object_path p -> Some p | _ -> None)
        in
        (paths unlocked, paths locked)
    | _ -> fail "SearchItems answered an unexpected reply"

let property c item name =
  match
    call c.bus ~path:item ~interface:"org.freedesktop.DBus.Properties"
      ~member:"Get"
      [String item_interface; String name]
  with
    | [Variant v] -> v
    | _ -> fail "%s answered an unexpected reply" name

let key_id c item =
  match property c item "Attributes" with
    | Array (_, pairs) ->
        List.find_map
          (function
            | Dbus.Dict_entry (String "keyId", String id) -> Some id | _ -> None)
          pairs
    | _ -> None

let bytes values =
  String.of_seq
    (Seq.filter_map
       (function Dbus.Byte b -> Some (Char.chr b) | _ -> None)
       (List.to_seq values))

let secret c item =
  match
    call c.bus ~path:item ~interface:item_interface ~member:"GetSecret"
      [Object_path c.session]
  with
    | [Struct [_; _; Array (_, value); _]] -> bytes value
    | _ -> fail "GetSecret answered an unexpected reply"

(* A put interrupted before its old item went leaves two; the newest is the
   last unlock's. *)
let newest c = function
  | [item] -> item
  | items ->
      let created item =
        match property c item "Created" with Dbus.Int64 t -> t | _ -> 0
      in
      fst
        (List.fold_left
           (fun (best, t) item ->
             let t' = created item in
             if t' > t then (item, t') else (best, t))
           ("", -1) items)

let get c ~domain =
  match search c domain with
    | [], [] -> None
    | [], _ :: _ -> fail "the item is locked"
    | unlocked, _ ->
        let item = newest c unlocked in
        Option.map (fun id -> (id, secret c item)) (key_id c item)

let delete_item c item =
  no_prompt
    (match
       call c.bus ~path:item ~interface:item_interface ~member:"Delete" []
     with
      | [prompt] -> prompt
      | _ -> Dbus.Unsupported)

let put c ~domain ~key_id:id ~key =
  let properties =
    Dbus.Array
      ( "{sv}",
        [
          Dict_entry
            ( String (item_interface ^ ".Label"),
              Variant (String ("tsync vault: " ^ domain)) );
          Dict_entry
            ( String (item_interface ^ ".Attributes"),
              Variant (attributes (entry domain @ [("keyId", id)])) );
        ] )
  in
  let value =
    Dbus.Struct
      [
        Object_path c.session;
        Array ("y", []);
        Array
          ( "y",
            List.of_seq
              (Seq.map (fun ch -> Dbus.Byte (Char.code ch)) (String.to_seq key))
          );
        String "application/octet-stream";
      ]
  in
  (match
     call c.bus ~path:default_collection
       ~interface:"org.freedesktop.Secret.Collection" ~member:"CreateItem"
       [properties; value; Bool true]
   with
    | [Object_path item; prompt] when item <> "/" -> no_prompt prompt
    | [_; prompt] ->
        no_prompt prompt;
        fail "CreateItem made no item"
    | _ -> fail "CreateItem answered an unexpected reply");
  (* §10.6: the earlier entry goes only once the new one stands. *)
  let unlocked, _ = search c domain in
  List.iter
    (fun item -> if key_id c item <> Some id then delete_item c item)
    unlocked

let delete c ~domain =
  match search c domain with
    | _, _ :: _ -> fail "the item is locked"
    | unlocked, [] -> List.iter (delete_item c) unlocked

let register () =
  if Dbus.available () then
    Tsync_owner.Keystore.register
      {
        name = "the Secret Service";
        put =
          (fun ~domain ~key_id ~key ->
            with_connection (fun c -> put c ~domain ~key_id ~key));
        get = (fun ~domain -> with_connection (get ~domain));
        delete = (fun ~domain -> with_connection (delete ~domain));
      }
