(** The collection run record R (spec 02 §2.12), on the collected main only. Its
    presence alone means a run is open; the collector alone parses it. *)

open Tsync_core
open Tsync_store

type phase = Opening | Marking | Closing | Abandoning

type t = {
  phase : phase;
  started : float;  (** seconds since the epoch *)
  cursor : string;  (** the last finished unit by name; [""] for none *)
  generation : int option;
      (** the run's odd generation, from closing on; a closing record without
          one is accepted and given one before the next doom step *)
}

(** [Unreadable]: present but not parseable, or an unknown phase. *)
type read = Absent | Unreadable | Record of t

val phase_name : phase -> string

(** [reconciling] reads as [Closing]; unknown fields are ignored. *)
val decode : string -> read

(** Never writes [reconciling]. *)
val encode : t -> string

val read : Store.t -> Domain_name.t -> read
val write : Store.t -> Domain_name.t -> t -> unit
val clear : Store.t -> Domain_name.t -> unit

(** [started × 1000], rounded, 13 digits. *)
val run_name : t -> string
