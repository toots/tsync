(** The frontends this build links (spec 08). Each frontend library registers
    itself when linked, so a config naming a type no linked library registered
    is refused when it is parsed. *)

open Tsync_core

(** A verb of [tsync <group> <verb>] (08 §2.1): [run] gets the resolved domain,
    one configured with this frontend, and the remaining arguments
    uninterpreted; it answers the exit status. *)
type command = {
  verb : string;
  doc : string;
  run : domain:string -> string list -> int;
}

type t = {
  fields : Field_spec.field list;
  presenting : [ `Per_domain | `Shared ] option;
      (** presents the domain to a user (one per domain), from a process per
          domain or from one process for all its domains *)
  commands_only : string option;
      (** never run by [tsync start], which refuses it with this text *)
  group : string option;  (** the CLI group; the frontend's name by default *)
  commands : command list;
}

(** At module initialisation, before any fiber runs. *)
val register : string -> t -> unit

val find : string -> t option

(** The registered types, sorted. *)
val names : unit -> string list
