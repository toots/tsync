(* A Secret Service on the bus at argv.(1): items in memory, every call
   appended to argv.(2), and the collection locked while argv.(3) exists. *)

open Tsync_core
open Tsync_dbus
open Tsync_tray_lib

type item = {
  path : string;
  attributes : (string * string) list;
  secret : Dbus.value list;
  created : int;
}

let items = ref []
let serial = ref 0
let session = "/org/freedesktop/secrets/session/1"

let attributes = function
  | Dbus.Array (_, entries) ->
      List.filter_map
        (function
          | Dbus.Dict_entry (String k, String v) -> Some (k, v) | _ -> None)
        entries
  | _ -> []

let matching wanted =
  List.filter
    (fun i -> List.for_all (fun kv -> List.mem kv i.attributes) wanted)
    !items

let paths l = Dbus.Array ("o", List.map (fun i -> Dbus.Object_path i.path) l)

let answer ~locked message =
  let item () = List.find (fun i -> i.path = Dbus.path message) !items in
  match (Dbus.member message, Dbus.body message) with
    | "OpenSession", _ -> Ok [Dbus.Variant (String ""); Object_path session]
    | "SearchItems", [wanted] ->
        let found = matching (attributes wanted) in
        Ok (if locked then [paths []; paths found] else [paths found; paths []])
    | "CreateItem", _ when locked ->
        Ok [Object_path "/"; Object_path "/org/freedesktop/secrets/prompt/1"]
    | ( "CreateItem",
        [Array (_, properties); Struct [_; _; Array (_, secret); _]; _] ) ->
        let attributes =
          List.concat_map
            (function
              | Dbus.Dict_entry
                  (String "org.freedesktop.Secret.Item.Attributes", Variant a)
                ->
                  attributes a
              | _ -> [])
            properties
        in
        incr serial;
        let path =
          Printf.sprintf "/org/freedesktop/secrets/collection/test/%d" !serial
        in
        items :=
          { path; attributes; secret; created = !serial }
          :: List.filter (fun i -> i.attributes <> attributes) !items;
        Ok [Object_path path; Object_path "/"]
    | "Get", [_; String "Attributes"] ->
        Ok
          [
            Variant
              (Array
                 ( "{ss}",
                   List.map
                     (fun (k, v) -> Dbus.Dict_entry (String k, String v))
                     (item ()).attributes ));
          ]
    | "Get", [_; String "Created"] -> Ok [Variant (Int64 (item ()).created)]
    | "GetSecret", _ ->
        Ok
          [
            Struct
              [
                Object_path session;
                Array ("y", []);
                Array ("y", (item ()).secret);
                String "application/octet-stream";
              ];
          ]
    | "Delete", _ when locked ->
        Ok [Dbus.Object_path "/org/freedesktop/secrets/prompt/2"]
    | "Delete", _ ->
        let path = Dbus.path message in
        items := List.filter (fun i -> i.path <> path) !items;
        Ok [Object_path "/"]
    | member, _ -> Error member

let () =
  let address = Sys.argv.(1) and log = Sys.argv.(2) and lock = Sys.argv.(3) in
  Rt.run_sync (fun () ->
      let bus = Bus.connect address in
      Rt.spawn ~name:"double" (fun () ->
          Bus.serve bus (fun message ->
              if Dbus.kind message = Method_call then begin
                Out_channel.with_open_gen [Open_append; Open_creat] 0o600 log
                  (fun oc -> output_string oc (Dbus.member message ^ "\n"));
                let reply =
                  match answer ~locked:(Sys.file_exists lock) message with
                    | Ok body -> Dbus.method_return message body
                    | Error member ->
                        Dbus.error_reply message
                          ~name:"org.freedesktop.DBus.Error.UnknownMethod"
                          member
                in
                Bus.send bus reply
              end));
      (match
         Bus.call bus ~timeout:5. ~destination:"org.freedesktop.DBus"
           ~path:"/org/freedesktop/DBus" ~interface:"org.freedesktop.DBus"
           ~member:"RequestName"
           [String "org.freedesktop.secrets"; Uint32 4]
       with
        | Ok [Uint32 1] -> print_endline "ready"
        | _ -> exit 1);
      Rt.sleep infinity)
