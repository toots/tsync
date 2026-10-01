(** Narration (spec 07 §5.1, 05 §4.1): what an operation tells a human operator
    following it with [--verbose], as plain sentences. An operation owns what it
    says; its caller only picks the sink. *)

type t = string -> unit

(** Says nothing: the default of every operation. *)
val none : t

(** One line on standard error, with the local time. *)
val stderr : t

val say : t -> ('a, unit, string, unit) format4 -> 'a

(** A sink for progress through a long step: at most one line every [every]
    seconds (default 10), the line built only when it is said. *)
val periodic : ?every:float -> t -> (unit -> string) -> unit

(** [1 chunk], [3 chunks]; [plural] when it is not the noun plus [s]. *)
val count : ?plural:string -> int -> string -> string

(** [42s], [6m12s], [2h05m]. *)
val duration : float -> string

(** [512 B], [3.0 MiB]. *)
val size : int -> string

(** Local [YYYY-MM-DD HH:MM]. *)
val date : float -> string
