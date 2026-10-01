(** A job's cancellation (spec 07 §2.5 "Bounded stop"): the checks that keep the
    next boundary within seconds of a cancel. *)

(** Fails REFUSED "cancelled" once [cancelled] holds. *)
val check : (unit -> bool) -> unit

(** Runs a read that may take long, abandoning it within a quarter second of a
    cancel; only for work that is safe to abandon midway. *)
val race : (unit -> bool) -> (unit -> 'a) -> 'a

(** [f] on each batch of at most [size] items (default 1000), checking for a
    cancel before each; [`Cancelled] leaves the rest undone. *)
val batches :
  ?size:int ->
  (unit -> bool) ->
  ('a list -> unit) ->
  'a list ->
  [ `Done | `Cancelled ]
