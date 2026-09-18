(** Waiting on a member only while it is thought to be there.

    Whoever has asked a member something, and has something else to do if it is
    down, stops waiting the moment it is found to be: the request climbs on
    behind, its answer going to nobody, which is what it costs not to need a way
    of calling a request back. *)
module Make (Io : Io.S) : sig
  (** [until_held health ~name ~op ask] is [ask ()], or {!Retry.held} as soon as
      [health] goes or stays out. *)
  val until_held :
    Health.t -> name:string -> op:string -> (unit -> 'a Io.t) -> 'a Io.t
end
