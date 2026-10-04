(** Narration (spec 07 §5.1, 05 §4.1): what an operation tells a human operator
    following it with [--verbose], as plain sentences. An operation owns what it
    says; its caller only picks the sink. *)

type t = {
  say : string -> unit;  (** a step or a decision, shown under [--verbose] *)
  progress : ?fraction:float -> string -> unit;
      (** where a long step is, shown unless [--quiet]: the sink decides how
          often it is drawn, so an operation reports every unit *)
}

(** Says nothing: the default of every operation. *)
val none : t

val say : t -> ('a, unit, string, unit) format4 -> 'a

(** [fraction] is the part done, from 0 to 1, when the step knows its total. *)
val progress : t -> ?fraction:float -> ('a, unit, string, unit) format4 -> 'a

(** [1 chunk], [3 chunks]; [plural] when it is not the noun plus [s]. *)
val count : ?plural:string -> int -> string -> string

(** [0m 42s], [6m 12s], [2h 5m], [3d 4h]: every duration shown to a person, in
    narration and in the status report alike. *)
val duration : float -> string

(** [512 B], [3.0 MiB], up to TiB (menu-model §3): every byte count shown to a
    person. *)
val size : int -> string

(** [size] per second. *)
val rate : float -> string

(** Local [YYYY-MM-DD HH:MM]. *)
val date : float -> string
