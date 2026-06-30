type rename_op = { dst : string; src : string; size : int64 option; is_dir : bool }

type op =
  [ `Delete of string
  | `Mkdir of string
  | `Put of string * int64
  | `Rename of rename_op
  | `Rmdir of string ]

val share_dir : unit -> string
val client_uuid : unit -> string
val entry_key : unit -> string
(** Accept bare entry key or full S3 key; extracts via Filename.basename *)
val timestamp_ms_of_filename : string -> int64
val client_uuid_of_filename : string -> string
val encode : op list -> string
val decode : string -> op list
val write_local_pending : entry_key:string -> op list -> unit
val delete_local_pending : entry_key:string -> unit
val local_pending_entries : uuid:string -> (string * op list) list
