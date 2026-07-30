type rename_op = {
  dst : string;
  src : string;
  size : int64 option;
  is_dir : bool;
}

type op =
  [ `Delete of string
  | `Mkdir of string
  | `Put of string * int64
  | `Rename of rename_op
  | `Rmdir of string ]

val timestamp_ms_of_filename : string -> int64
val client_uuid_of_filename : string -> string

val relative_path : string -> string
(** [relative_path entry_key] is ["<YYYY-MM>/<entry_key>"], the entry's path
    relative to the journal prefix. Both levels sort chronologically, so the
    lexicographic order readers rely on is unchanged; {!Filename.basename}
    recovers the entry key from a listing. *)
val encode : op list -> string
val decode : string -> op list

module Make (C : Conf.S) : sig
  val client_uuid : unit -> string
  val entry_key : unit -> string
  val write_local_pending : entry_key:string -> op list -> unit Lwt.t
  val delete_local_pending : entry_key:string -> unit Lwt.t
  val local_pending_entries : uuid:string -> (string * op list) list Lwt.t
end
