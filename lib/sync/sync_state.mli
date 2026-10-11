(** The sync state of one domain (spec 03 §2.7–2.8, §3.2): the position, the
    before-values, the in-flight record and the arrival record, under
    [<data_dir>/sync/<domain>/].

    Only the owner writes it. Before-values are held in memory once loaded; the
    files are their durable form. *)

open Tsync_core

type t

(** Loads every record; an unparseable one is set aside and makes {!needs_state}
    true. *)
val open_ : data_dir:string -> Domain_name.t -> t

(** A record was set aside: the client arrives by state before it pushes. *)
val needs_state : t -> bool

val state_read : t -> unit
val position : t -> int option
val set_position : t -> int -> unit

(** The before-value of a key: [None] when the key is clean. *)
val before_file : t -> Algebra.place -> Log_entry.value option option

val before_folder : t -> Folder_id.t -> Algebra.place option option

(** Record the main's value at a clean key; nothing for a key that has one. With
    [durable] false the record is written and not yet durable, until {!harden}.
*)
val record_file :
  ?durable:bool -> t -> Algebra.place -> Log_entry.value option -> unit

val record_folder : t -> Folder_id.t -> Algebra.place option -> unit

(** Replace or create, durably: the [Won] step and an arrival. *)
val set_file : t -> Algebra.place -> Log_entry.value option -> unit

val set_folder : t -> Folder_id.t -> Algebra.place option -> unit
val drop : t -> Algebra.key -> unit
val harden : t -> Algebra.key -> unit

(** One command per before-value, from the before-value to [None]: the caller
    fills in [L]. *)
val pending : t -> Log_entry.command list

val pending_count : t -> int

type in_flight = { n : int; body : string }

val in_flight : t -> in_flight option
val set_in_flight : t -> in_flight -> unit
val clear_in_flight : t -> unit

(** One change of the local tree an arrival makes (03 §2.7). *)
type step =
  | Move of Algebra.place * Algebra.place
  | File of Algebra.place * Manifest.t option
  | Folder of Folder_id.t * Algebra.place option

type settled =
  | Drop
  | Before_file of Log_entry.value option
  | Before_folder of Algebra.place option

(** [view]: on a lazy tree, the folder whose position the arrival sets. *)
type arrival = {
  head : int;
  view : Folder_id.t option;
  feed : string list;
  steps : step list;
  before : (Algebra.key * settled) list;
}

val arrival : t -> arrival option
val set_arrival : t -> arrival -> unit
val clear_arrival : t -> unit
val encode_arrival : arrival -> string
val decode_arrival : string -> arrival option
