(** A ceiling on how much of something runs at once.

    A pool stands for a resource, not for a piece of work: the width belongs to
    whoever knows what shares the process, and the code inside only asks. *)

(** Raised by {!Make.use} when the pool is full and its queue is capped. *)
exception Busy

module Make (Io : Io.S) : sig
  type t

  (** [create ?max_waiting ?name ~max ()] admits [max] at once. [max_waiting]
      caps the queue behind that, after which admission is refused rather than
      queued. A [name] registers the pool for {!totals}; name only a pool
      created once at startup, since nothing here is ever pruned. *)
  val create : ?max_waiting:int -> ?name:string -> max:int -> unit -> t

  (** The pool already created under [key], or a new one remembered there. *)
  val shared : key:string -> name:string -> max:int -> unit -> t

  val in_flight : t -> int

  (** How many are queued for a slot. Above zero is the difference between work
      that is slow and work that is behind a bound, which nothing outside could
      tell apart. *)
  val waiting : t -> int

  val width : t -> int

  (** Every named pool as [(name, in_flight, waiting, width)], in creation
      order, so one run's report reads against another's. Pools sharing a name
      are summed. *)
  val totals : unit -> (string * int * int * int) list

  (** Run [f] holding a slot, releasing it however [f] ends. Fails with {!Busy}
      rather than queueing past [max_waiting]. *)
  val use : t -> (unit -> 'a Io.t) -> 'a Io.t

  (** {!use}, calling [busy] instead of failing. *)
  val use_or : t -> busy:(unit -> 'a Io.t) -> (unit -> 'a Io.t) -> 'a Io.t

  (** These three run the whole list, each element through the pool, so the
      bound is on what is in flight rather than on what is offered. *)
  val map_with : t -> ('a -> 'b Io.t) -> 'a list -> 'b list Io.t

  val iter_with : t -> ('a -> unit Io.t) -> 'a list -> unit Io.t
  val filter_map_with : t -> ('a -> 'b option Io.t) -> 'a list -> 'b list Io.t

  (** [each ~width next] runs [width] workers, each taking jobs from [next]
      until it answers [None]. For a source that cannot be listed up front.
      Workers stop at the first failure rather than draining what is left, and
      that failure is re-raised. *)
  val each : width:int -> (unit -> (unit -> unit Io.t) option) -> unit Io.t
end
