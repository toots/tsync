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
