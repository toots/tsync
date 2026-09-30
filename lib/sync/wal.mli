(** The WAL record (spec 04 §2.8, wal-and-journal §4.1): one per unit of owed
    work, named by the entry key it will be published under. *)

type state = Intent | Prepared | Executed

(** The expected prior record of a [delete] or file [rename]: its content
    identity, none, or unknown. *)
type prior = Unknown | Nothing | Content of string

type record = {
  state : state;
  attempts : int;
  ops : Op.t list;
  priors : (int * prior) list;  (** by op index; local only *)
  local_from : (int * string) list;
      (** where a retargeted rename's file sits until redone *)
  last_error : (string * string) option;
      (** kind name and detail, reported only *)
}

val state_name : state -> string
val encode : record -> string

(** [None]: unparseable (set aside). Accepts the op-list form, reading it as an
    intent; an unknown state reads as [Intent]. *)
val decode : string -> record option

(** At least one op and no put. *)
val is_metadata : record -> bool

val puts_only : record -> bool
val prior : record -> int -> prior
