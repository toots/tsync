(** The process-wide stop flag (spec 01 §9). A stop is not a cancellation: waits
    that are stop-aware end with {!Stopping}, running work may finish. *)

exception Stopping

(** Idempotent: sets the flag and runs the hooks once, in registration order. *)
val request : unit -> unit

val requested : unit -> bool

(** Register a hook; one registered after the request runs at once. The result
    unregisters it. *)
val on_request : (unit -> unit) -> unit -> unit

(** Raises {!Stopping} if a stop was requested. *)
val check : unit -> unit

(** Returns once a stop is requested. *)
val wait : unit -> unit

(** Stop-aware sleep: ends early with {!Stopping}. *)
val sleep : float -> unit

(** [STOP_GRACE], seconds. *)
val grace : float
