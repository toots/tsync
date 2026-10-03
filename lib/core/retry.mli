(** The retry ladder (spec 01 §7): one request against one member. Which
    failures are retried is decided by their kind, never their text. *)

val attempts : int

(** The delay before attempt [n + 1]: exponential, capped, jittered. *)
val delay : int -> float

(** Run [f], retrying transient failures and feeding the member's breaker. Stops
    and cancellations pass through at once; a considered answer costs one
    attempt. [deadline] is monotonic. *)
val ladder :
  ?attempts:int ->
  ?deadline:float ->
  ?health:Health.t ->
  op:string ->
  (unit -> 'a) ->
  'a

(** Race [ask] against the member tripping; raise UNREACHABLE when it does. *)
val until_held : Health.t -> (unit -> 'a) -> 'a
