type raw_request = {
  raw_kind : int;
  transfer : int64;
  request_key : int64;
  identity : string;
  path : string;
  file_size : int;
  process_id : int;
  flags : int;
  offset : int;
  length : int;
  optional_offset : int;
  optional_length : int;
  target : string;
}

type request = {
  kind :
    [ `Fetch_data
    | `Cancel_fetch_data
    | `Fetch_placeholders
    | `Cancel_fetch_placeholders
    | `Close_completion
    | `Dehydrate
    | `Delete
    | `Rename
    | `Other of int ];
  transfer : int64;
  request_key : int64;
  identity : string;
  path : string;
  file_size : int;
  process_id : int;
  flags : int;
  offset : int;
  length : int;
  optional_offset : int;
  optional_length : int;
  target : string;
}

(* CF_CALLBACK_TYPE values. *)
let kind_of = function
  | 0 -> `Fetch_data
  | 2 -> `Cancel_fetch_data
  | 3 -> `Fetch_placeholders
  | 4 -> `Cancel_fetch_placeholders
  | 6 -> `Close_completion
  | 7 -> `Dehydrate
  | 9 -> `Delete
  | 11 -> `Rename
  | n -> `Other n

let on_callback handle =
  Callback.register "tsync_cf_callback" (fun (r : raw_request) ->
      handle
        {
          kind = kind_of r.raw_kind;
          transfer = r.transfer;
          request_key = r.request_key;
          identity = r.identity;
          path = r.path;
          file_size = r.file_size;
          process_id = r.process_id;
          flags = r.flags;
          offset = r.offset;
          length = r.length;
          optional_offset = r.optional_offset;
          optional_length = r.optional_length;
          target = r.target;
        })

type connection = int64

external connect : string -> connection = "tsync_cf_connect"
external disconnect : connection -> unit = "tsync_cf_disconnect"

type status =
  [ `Success
  | `Not_in_sync
  | `Collision
  | `Not_empty
  | `Access_denied
  | `Invalid
  | `Network_unavailable
  | `Unsuccessful
  | `Cancelled ]

(* NTSTATUS values, from Microsoft's API metadata. *)
let ntstatus = function
  | `Success -> 0l
  | `Not_in_sync -> 0xC000CF08l
  | `Collision -> 0xC0000035l
  | `Not_empty -> 0xC0000101l
  | `Access_denied -> 0xC0000022l
  | `Invalid -> 0xC000CF0Bl
  | `Network_unavailable -> 0xC000CF11l
  | `Unsuccessful -> 0xC000CF12l
  | `Cancelled -> 0xC000CF1Bl

external ack_ : connection -> int64 -> int64 -> int -> int32 -> unit
  = "tsync_cf_ack"

let ack c (r : request) what status =
  ack_ c r.transfer r.request_key
    (match what with `Delete -> 0 | `Rename -> 1 | `Dehydrate -> 2)
    (ntstatus status)

type placeholder = {
  name : string;
  is_dir : bool;
  size : int;
  mtime : float;
  identity : string;
  read_only : bool;
}

external transfer_placeholders_ :
  connection ->
  int64 ->
  int64 ->
  int32 ->
  (string * bool * int * float * string * bool) array ->
  unit = "tsync_cf_transfer_placeholders"

let transfer_placeholders c (r : request) status entries =
  transfer_placeholders_ c r.transfer r.request_key (ntstatus status)
    (Array.of_list
       (List.map
          (fun p ->
            (p.name, p.is_dir, p.size, p.mtime, p.identity, p.read_only))
          entries))

external transfer_data_ :
  connection ->
  int64 ->
  int64 ->
  int32 ->
  Tsync_core.Bigstring.t ->
  int ->
  int ->
  unit = "tsync_cf_transfer_data_bytecode" "tsync_cf_transfer_data_native"

let transfer_data c (r : request) status buffer ~offset ~length =
  transfer_data_ c r.transfer r.request_key (ntstatus status) buffer offset
    length

external register_ : string -> string -> string -> string -> string -> unit
  = "tsync_cf_register"

let register ~id ~path ~display_name ~version ~icon =
  register_ id path display_name version icon

external unregister : string -> unit = "tsync_cf_unregister"
external user_sid : unit -> string = "tsync_cf_user_sid"
external upcase : string -> string = "tsync_cf_upcase"
external identity : string -> string option = "tsync_cf_identity"
external hydrate : string -> unit = "tsync_cf_hydrate"

type state = {
  is_dir : bool;
  other_reparse : bool;
  placeholder : bool;
  in_sync : bool;
  identity : string;
  usn : int64;
  unpopulated : bool;
  dehydrated : bool;
  pin : [ `Unspecified | `Pinned | `Unpinned | `Excluded | `Inherit ];
}

type raw_state = {
  r_is_dir : bool;
  r_other_reparse : bool;
  r_placeholder : bool;
  r_in_sync : bool;
  r_identity : string;
  r_usn : int64;
  r_unpopulated : bool;
  r_dehydrated : bool;
  r_pin : int;
}

external raw_state : string -> raw_state option = "tsync_cf_state"

let state path =
  Option.map
    (fun r ->
      {
        is_dir = r.r_is_dir;
        other_reparse = r.r_other_reparse;
        placeholder = r.r_placeholder;
        in_sync = r.r_in_sync;
        identity = r.r_identity;
        usn = r.r_usn;
        unpopulated = r.r_unpopulated;
        dehydrated = r.r_dehydrated;
        pin =
          (match r.r_pin with
            | 1 -> `Pinned
            | 2 -> `Unpinned
            | 3 -> `Excluded
            | 4 -> `Inherit
            | _ -> `Unspecified);
      })
    (raw_state path)

external dehydrate : string -> unit = "tsync_cf_dehydrate"

type watch = int64

external watch_open : string -> watch = "tsync_cf_watch_open"

external watch_read : watch -> (int * string) list option
  = "tsync_cf_watch_read"

external watch_close : watch -> unit = "tsync_cf_watch_close"

type held = int64

external hold : string -> held option = "tsync_cf_hold"
external held_usn : held -> int64 = "tsync_cf_held_usn"
external release : held -> unit = "tsync_cf_release"

external set_identity_ : held -> bool -> string -> bool -> int -> unit
  = "tsync_cf_set_identity"

let set_identity ?size h ~placeholder identity ~in_sync =
  set_identity_ h placeholder identity in_sync (Option.value ~default:(-1) size)

external create_ :
  string -> string -> bool -> int -> float -> string -> bool -> unit
  = "tsync_cf_create_bytecode" "tsync_cf_create_native"

let create dir (p : placeholder) =
  create_ dir p.name p.is_dir p.size p.mtime p.identity p.read_only

external refresh_ :
  string -> int64 -> bool -> int -> float -> string -> bool -> bool -> bool
  = "tsync_cf_refresh_bytecode" "tsync_cf_refresh_native"

let refresh path ~usn (p : placeholder) ~dehydrate =
  refresh_ path usn p.is_dir p.size p.mtime p.identity p.read_only dehydrate

external revert : string -> unit = "tsync_cf_revert"
external registered : unit -> (string * string) list = "tsync_cf_registered"
