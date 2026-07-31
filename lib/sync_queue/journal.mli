type rename_op = {
  dst : string;
  src : string;
  size : int64 option;
  is_dir : bool;
  id : string option;  (** The folder's id, when [is_dir]. See {!op}. *)
}

(** Directory ops carry the folder's stable id alongside its path. A peer
    applies the op before anything asks it about the folder, and applying a
    removal destroys the local marker the id would have been read from — so an
    id not recorded here cannot be recovered afterwards, and the folder cannot
    be named to anything that knows it by id. [None] for entries written before
    this was carried, and for a client that has no id for the folder. *)
type op =
  [ `Delete of string
  | `Mkdir of string * string option
  | `Put of string * int64
  | `Rename of rename_op
  | `Rmdir of string * string option ]

val timestamp_ms_of_filename : string -> int64
val client_uuid_of_filename : string -> string

(** [relative_path entry_key] is ["<YYYY-MM>/<entry_key>"], the entry's path
    relative to the journal prefix. Both levels sort chronologically, so the
    lexicographic order readers rely on is unchanged; {!Filename.basename}
    recovers the entry key from a listing. *)
val relative_path : string -> string

val encode : op list -> string
val decode : string -> op list

module Make (C : Conf.S) : sig
  val client_uuid : unit -> string
  val entry_key : unit -> string
  val write_local_pending : entry_key:string -> op list -> unit Lwt.t
  val delete_local_pending : entry_key:string -> unit Lwt.t
  val local_pending_entries : uuid:string -> (string * op list) list Lwt.t
end
