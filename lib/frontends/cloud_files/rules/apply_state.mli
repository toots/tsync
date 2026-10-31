(** The apply's state file (cloud-files §10.1): the last change anchor whose ops
    are applied, and the folders whose apply could not finish. The host reads it
    at start and writes it after each round, by durable replace. *)

type t = { anchor : string; pending : string list }

(** [anchor] [""] and every populated folder pending: what an absent or
    unreadable file means. *)
val fresh : t

val encode : t -> string

(** [None] for a file that does not decode, which the caller reads as {!fresh}.
*)
val decode : string -> t option
