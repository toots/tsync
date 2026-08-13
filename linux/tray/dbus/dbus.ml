type connection
type message
type iter

exception Error of string * string

let () = Callback.register_exception "tsync.dbus.error" (Error ("", ""))

type value =
  | Byte of int
  | Bool of bool
  | Int16 of int
  | Uint16 of int
  | Int32 of int32
  | Uint32 of int32
  | Int64 of int64
  | Uint64 of int64
  | Double of float
  | String of string
  | Path of string
  | Sig of string
  | Array of string * value list
  | Struct of value list
  | Variant of value
  | Dict of value * value

(* The wire type codes are the ASCII characters of the signature language, which
   is why they read as characters here and are compared as ints in C. *)
let t_byte = Char.code 'y'
let t_bool = Char.code 'b'
let t_int16 = Char.code 'n'
let t_uint16 = Char.code 'q'
let t_int32 = Char.code 'i'
let t_uint32 = Char.code 'u'
let t_int64 = Char.code 'x'
let t_uint64 = Char.code 't'
let t_double = Char.code 'd'
let t_string = Char.code 's'
let t_path = Char.code 'o'
let t_sig = Char.code 'g'
let t_array = Char.code 'a'
let t_struct = Char.code 'r'
let t_variant = Char.code 'v'
let t_dict = Char.code 'e'

(* [r] and [e] are what libdbus reports for a struct and a dict entry, but the
   signature language spells them with brackets. *)
let rec signature_of = function
  | Byte _ -> "y"
  | Bool _ -> "b"
  | Int16 _ -> "n"
  | Uint16 _ -> "q"
  | Int32 _ -> "i"
  | Uint32 _ -> "u"
  | Int64 _ -> "x"
  | Uint64 _ -> "t"
  | Double _ -> "d"
  | String _ -> "s"
  | Path _ -> "o"
  | Sig _ -> "g"
  | Array (elt, _) -> "a" ^ elt
  | Struct vs -> "(" ^ String.concat "" (List.map signature_of vs) ^ ")"
  | Variant _ -> "v"
  | Dict (k, v) -> "{" ^ signature_of k ^ signature_of v ^ "}"

let dict_sv fields =
  Array ("{sv}", List.map (fun (k, v) -> Dict (String k, Variant v)) fields)

external session_bus : unit -> connection = "tsync_dbus_bus_get"
external close : connection -> unit = "tsync_dbus_close"

external request_name : connection -> string -> int -> int
  = "tsync_dbus_request_name"

external add_match : connection -> string -> unit = "tsync_dbus_add_match"
external flush : connection -> unit = "tsync_dbus_flush"
external send : connection -> message -> unit = "tsync_dbus_send"

external send_with_reply_and_block : connection -> message -> int -> message
  = "tsync_dbus_send_with_reply_and_block"

external read_write : connection -> int -> bool = "tsync_dbus_read_write"
external pop_message : connection -> message option = "tsync_dbus_pop_message"

external new_method_call : string -> string -> string -> string -> message
  = "tsync_dbus_new_method_call"

external new_signal : string -> string -> string -> message
  = "tsync_dbus_new_signal"

external new_method_return : message -> message = "tsync_dbus_new_method_return"

external new_error : message -> string -> string -> message
  = "tsync_dbus_new_error"

external message_type : message -> int = "tsync_dbus_message_type"
external message_path : message -> string = "tsync_dbus_message_path"
external message_interface : message -> string = "tsync_dbus_message_interface"
external message_member : message -> string = "tsync_dbus_message_member"
external message_sender : message -> string = "tsync_dbus_message_sender"

external message_error_name : message -> string
  = "tsync_dbus_message_error_name"

external message_no_reply : message -> bool = "tsync_dbus_message_no_reply"
external iter_init_append : message -> iter = "tsync_dbus_iter_init_append"
external iter_open : iter -> int -> string -> iter = "tsync_dbus_iter_open"
external iter_close : iter -> iter -> unit = "tsync_dbus_iter_close"

external iter_append_int : iter -> int -> int64 -> unit
  = "tsync_dbus_iter_append_int"

external iter_append_double : iter -> float -> unit
  = "tsync_dbus_iter_append_double"

external iter_append_string : iter -> int -> string -> unit
  = "tsync_dbus_iter_append_string"

external iter_init : message -> iter = "tsync_dbus_iter_init"
external iter_arg_type : iter -> int = "tsync_dbus_iter_arg_type"

external iter_element_signature : iter -> string
  = "tsync_dbus_iter_element_signature"

external iter_next : iter -> bool = "tsync_dbus_iter_next"
external iter_recurse : iter -> iter = "tsync_dbus_iter_recurse"
external iter_get_int : iter -> int64 = "tsync_dbus_iter_get_int"
external iter_get_double : iter -> float = "tsync_dbus_iter_get_double"
external iter_get_string : iter -> string = "tsync_dbus_iter_get_string"

let method_call = 1
let method_return = 2
let error = 3
let signal = 4

let message_new_method_call ~dest ~path ~iface ~member =
  new_method_call dest path iface member

let message_new_signal ~path ~iface ~member = new_signal path iface member

(* Where the four container kinds are handled, and the only reason the C side
   offers an iterator instead of a marshaller. *)
let rec append_value iter = function
  | Byte n -> iter_append_int iter t_byte (Int64.of_int n)
  | Bool b -> iter_append_int iter t_bool (if b then 1L else 0L)
  | Int16 n -> iter_append_int iter t_int16 (Int64.of_int n)
  | Uint16 n -> iter_append_int iter t_uint16 (Int64.of_int n)
  | Int32 n -> iter_append_int iter t_int32 (Int64.of_int32 n)
  | Uint32 n -> iter_append_int iter t_uint32 (Int64.of_int32 n)
  | Int64 n -> iter_append_int iter t_int64 n
  | Uint64 n -> iter_append_int iter t_uint64 n
  | Double f -> iter_append_double iter f
  | String s -> iter_append_string iter t_string s
  | Path s -> iter_append_string iter t_path s
  | Sig s -> iter_append_string iter t_sig s
  | Array (elt, vs) -> container iter t_array elt vs
  | Struct vs -> container iter t_struct "" vs
  | Dict (k, v) -> container iter t_dict "" [k; v]
  (* Only a variant carries the signature of what is inside it; a struct's and a
     dict entry's are implied by their contents, and libdbus rejects one given
     explicitly. *)
  | Variant v -> container iter t_variant (signature_of v) [v]

and container iter code sign vs =
  let sub = iter_open iter code sign in
  List.iter (append_value sub) vs;
  iter_close iter sub

let append msg vs =
  let iter = iter_init_append msg in
  List.iter (append_value iter) vs

(* Reading needs no signature: the wire is self-describing, so the arg type at
   the cursor says what to do next. *)
let rec read_value iter =
  let code = iter_arg_type iter in
  if code = t_byte then Byte (Int64.to_int (iter_get_int iter))
  else if code = t_bool then Bool (iter_get_int iter <> 0L)
  else if code = t_int16 then Int16 (Int64.to_int (iter_get_int iter))
  else if code = t_uint16 then Uint16 (Int64.to_int (iter_get_int iter))
  else if code = t_int32 then Int32 (Int64.to_int32 (iter_get_int iter))
  else if code = t_uint32 then Uint32 (Int64.to_int32 (iter_get_int iter))
  else if code = t_int64 then Int64 (iter_get_int iter)
  else if code = t_uint64 then Uint64 (iter_get_int iter)
  else if code = t_double then Double (iter_get_double iter)
  else if code = t_string then String (iter_get_string iter)
  else if code = t_path then Path (iter_get_string iter)
  else if code = t_sig then Sig (iter_get_string iter)
  else if code = t_array then (
    (* The element signature has to be taken before recursing: an empty array
       has nothing inside to read it off. [get_signature] answers the whole
       array's, so drop the leading 'a'. *)
    let whole = iter_element_signature iter in
    let elt =
      if String.length whole > 1 then
        String.sub whole 1 (String.length whole - 1)
      else ""
    in
    Array (elt, read_sequence (iter_recurse iter)))
  else if code = t_struct then Struct (read_sequence (iter_recurse iter))
  else if code = t_variant then (
    match read_sequence (iter_recurse iter) with
      | [v] -> Variant v
      | _ -> failwith "dbus: malformed variant")
  else if code = t_dict then (
    match read_sequence (iter_recurse iter) with
      | [k; v] -> Dict (k, v)
      | _ -> failwith "dbus: malformed dict entry")
  else
    failwith
      (Printf.sprintf "dbus: unsupported type '%c'" (Char.chr (code land 0xff)))

and read_sequence iter =
  (* [invalid] -- 0 -- is how libdbus spells "past the end", which is also the
     empty container. *)
  if iter_arg_type iter = 0 then []
  else (
    let v = read_value iter in
    if iter_next iter then v :: read_sequence iter else [v])

let body msg = read_sequence (iter_init msg)

let emit conn ~path ~iface ~member args =
  let msg = message_new_signal ~path ~iface ~member in
  append msg args;
  send conn msg

let reply conn to_ args =
  let msg = new_method_return to_ in
  append msg args;
  send conn msg

let error_reply conn to_ name text = send conn (new_error to_ name text)

let unknown_method conn msg =
  error_reply conn msg "org.freedesktop.DBus.Error.UnknownMethod"
    (Printf.sprintf "no such method: %s" (message_member msg))

let unknown_property conn msg name =
  error_reply conn msg "org.freedesktop.DBus.Error.UnknownProperty"
    (Printf.sprintf "no such property: %s" name)

let unknown_interface conn msg =
  error_reply conn msg "org.freedesktop.DBus.Error.UnknownInterface"
    (Printf.sprintf "no such interface: %s" (message_interface msg))

let read_only_property conn msg =
  error_reply conn msg "org.freedesktop.DBus.Error.PropertyReadOnly"
    "these properties are read-only"

let introspection own =
  {xml|<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="org.freedesktop.DBus.Introspectable">
    <method name="Introspect"><arg name="xml" type="s" direction="out"/></method>
  </interface>
  <interface name="org.freedesktop.DBus.Peer">
    <method name="Ping"/>
  </interface>
  <interface name="org.freedesktop.DBus.Properties">
    <method name="Get">
      <arg name="interface" type="s" direction="in"/>
      <arg name="property" type="s" direction="in"/>
      <arg name="value" type="v" direction="out"/>
    </method>
    <method name="GetAll">
      <arg name="interface" type="s" direction="in"/>
      <arg name="properties" type="a{sv}" direction="out"/>
    </method>
    <method name="Set">
      <arg name="interface" type="s" direction="in"/>
      <arg name="property" type="s" direction="in"/>
      <arg name="value" type="v" direction="in"/>
    </method>
  </interface>
|xml}
  ^ own ^ "</node>"

let call conn ?(timeout = 5000) ~dest ~path ~iface ~member args =
  let msg = message_new_method_call ~dest ~path ~iface ~member in
  append msg args;
  let reply = send_with_reply_and_block conn msg timeout in
  if message_type reply = error then
    raise
      (Error
         ( message_error_name reply,
           match body reply with String s :: _ -> s | _ -> "" ));
  body reply

(* DBUS_NAME_FLAG_DO_NOT_QUEUE; DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER. *)
let request_name_exclusive conn name = request_name conn name 4 = 1
