exception Error of string

let () = Callback.register_exception "tsync_dbus_error" (Error "")

type value =
  | Byte of int
  | Bool of bool
  | Int32 of int
  | Uint32 of int
  | Int64 of int
  | Double of float
  | String of string
  | Object_path of string
  | Signature of string
  | Array of string * value list
  | Struct of value list
  | Variant of value
  | Dict_entry of value * value
  | Unsupported

type kind = Method_call | Method_return | Error_reply | Signal
type message
type t

external kind : message -> kind = "tsync_dbus_message_kind"
external path : message -> string = "tsync_dbus_message_path"
external interface : message -> string = "tsync_dbus_message_interface"
external member : message -> string = "tsync_dbus_message_member"
external error_name : message -> string = "tsync_dbus_message_error_name"
external reply_serial : message -> int = "tsync_dbus_message_reply_serial"
external no_reply : message -> bool = "tsync_dbus_message_no_reply"
external body : message -> value list = "tsync_dbus_message_body"
external append : message -> value list -> unit = "tsync_dbus_message_append"

external new_method_call : string -> string -> string -> string -> message
  = "tsync_dbus_new_method_call"

external new_method_return : message -> message = "tsync_dbus_new_method_return"

external new_error : message -> string -> string -> message
  = "tsync_dbus_new_error"

external new_signal : string -> string -> string -> message
  = "tsync_dbus_new_signal"

external connect : string -> t = "tsync_dbus_connect"
external descriptor : t -> Unix.file_descr = "tsync_dbus_descriptor"
external send : t -> message -> int = "tsync_dbus_send"
external read_write : t -> bool = "tsync_dbus_read_write"
external pop : t -> message option = "tsync_dbus_pop"
external has_output : t -> bool = "tsync_dbus_has_output"

(* libdbus refuses a string that is not UTF-8 or holds a NUL. *)
let text s =
  if String.is_valid_utf_8 s && not (String.contains s '\000') then s
  else (
    let b = Buffer.create (String.length s) in
    let rec go i =
      if i < String.length s then (
        let d = String.get_utf_8_uchar s i in
        if Uchar.utf_decode_is_valid d && Uchar.utf_decode_uchar d <> Uchar.min
        then Buffer.add_utf_8_uchar b (Uchar.utf_decode_uchar d)
        else Buffer.add_utf_8_uchar b Uchar.rep;
        go (i + Uchar.utf_decode_length d))
    in
    go 0;
    Buffer.contents b)

let rec clean = function
  | String s -> String (text s)
  | Array (signature, l) -> Array (signature, List.map clean l)
  | Struct l -> Struct (List.map clean l)
  | Variant v -> Variant (clean v)
  | Dict_entry (k, v) -> Dict_entry (clean k, clean v)
  | v -> v

let filled message values =
  append message (List.map clean values);
  message

let method_call ~destination ~path ~interface ~member values =
  filled (new_method_call destination path interface member) values

let method_return call values = filled (new_method_return call) values
let error_reply call ~name text_ = new_error call name (text text_)

let signal ~path ~interface ~member values =
  filled (new_signal path interface member) values
