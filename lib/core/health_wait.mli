(** Waiting on a member only while it is thought to be there.

    Whoever has asked a member something, and has something else to do if it is
    down, stops waiting the moment it is found to be, and the request is called
    back: left to itself it would climb the rest of its ladder for nobody. *)
module Make (Io : Io.S) (_ : Clock.S with type 'a io := 'a Io.t) : sig
  (** [until_held health ~name ~op ask] is [ask ()], or {!Retry.held} as soon as
      [health] goes or stays out. Cancelling it cancels [ask]. *)
  val until_held :
    Health.t -> name:string -> op:string -> (unit -> 'a Io.t) -> 'a Io.t
end
