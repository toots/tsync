(** Upload admission per network link (spec algorithms/uplink-governor.md §4.1–
    §4.3, 06 §6): a token bucket with an in-flight window, and a FIFO line that
    small bodies may pass by a bounded amount. The rate is the link's [maxRate];
    a link without one admits at once until the delay-driven law and the lease
    protocol (§4.4–§4.5) exist. *)

type t

(** Admits everything at once and counts nothing: a store without a link. *)
val none : t

(** The admission of a named link, one per process, shared by every store on it.
*)
val link : string -> enabled:bool -> max_rate:int option -> t

type ticket

(** Suspends until the bytes may be sent; STOPPING once the process stops. *)
val acquire : t -> int -> ticket

(** Admitted now or refused, never waits. *)
val try_acquire : t -> int -> ticket option

val completed : t -> ticket -> unit
val abandoned : t -> ticket -> unit

(** Bodies waiting in line. *)
val waiting : t -> int

(** One attempt carrying [bytes] upstream, admitted per [mode] and reported
    exactly once; a best-effort attempt refused admission is cancelled without
    running. *)
val admitted : t -> Store.mode -> int -> (unit -> 'a) -> 'a

module Budget : sig
  type t

  val create : rate:float -> now:float -> t
  val admits : t -> now:float -> int -> bool
  val take : t -> now:float -> int -> unit
  val release : t -> int -> unit
  val wait_for : t -> now:float -> int -> float
end
