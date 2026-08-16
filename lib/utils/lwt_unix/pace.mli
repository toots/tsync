(** How often a long-running job says where it got to.

    Every op here can run for minutes — a namespace listing, a shard sweep, a
    million-chunk copy — so each grew a clock of its own with the same interval
    and the same seed. One rate, in one place, is also what makes two reports
    comparable. *)

type t

(** [interval] defaults to one second, which is what a progress line is for. *)
val create : ?interval:float -> unit -> t

(** Run [f] if [interval] has passed since it last ran, or if [force].

    [key] gives a phase its own clock: phases overlap, and one whose first item
    lands inside another's interval would otherwise report nothing at all until
    a second went by. *)
val fire : t -> ?key:string -> ?force:bool -> (unit -> unit) -> unit
