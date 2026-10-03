(** Named entries filled at module initialisation, before any fiber runs, and
    only read afterwards. *)

type 'a t

val create : unit -> 'a t
val register : 'a t -> string -> 'a -> unit
val find : 'a t -> string -> 'a option

(** The registered names, sorted. *)
val names : 'a t -> string list
