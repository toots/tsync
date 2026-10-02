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
  fids : (int * string) list;
      (** by op index: the file id of the file an op names, read when the local
          operation ran; local only, copied into the applied log *)
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

(** The file an op names, and how: a put's path, a delete's path, a file
    rename's source; [None] for folder ops. *)
val subject : Op.t -> ([ `Put | `Delete | `Rename ] * string) option

(** [r]'s file ids re-indexed onto [ops], a rewrite of [r.ops]: an op keeps the
    id of the op that named the same file the same way. *)
val carry_fids : record -> Op.t list -> (int * string) list
