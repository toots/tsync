(** The backend drivers this build links (spec 06 §5). Each driver library
    registers itself when linked, so a config naming a type no linked library
    registered is refused when it is parsed. *)

open Tsync_core

type t = {
  fields : Field_spec.field list;
  linkless : bool;  (** a local store: no network link to govern *)
  create :
    domain:Domain_name.t ->
    name:string ->
    (string * Field_spec.value) list ->
    Store.t;
      (** reaches no network and touches no file *)
}

(** At module initialisation, before any fiber runs. *)
val register : string -> t -> unit

val find : string -> t option

(** The registered types, sorted. *)
val names : unit -> string list
