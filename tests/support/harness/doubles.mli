(** Stores that behave badly on purpose.

    Each was written out per test, so the same "a store that is down" existed
    several times over and a new method on {!Backend.S} had to be stubbed into
    every copy. *)

(** Every operation fails with [why], which appears in the report a test prints,
    so two unreachable stores in one domain can be told apart. *)
module Down (M : sig
  val why : string
end) : Backend_lwt.Store

(** Never answers at all: every operation is a promise that stays pending, for
    the tests whose subject is the answer that does not come. *)
module Hung : Backend_lwt.Store

(** [Real] behind a link that can go down. A request made while it is down
    stalls until the link returns and then goes through, which is what an outage
    is, as opposed to a store that refuses. Every request is counted, stalled
    ones included, so a test can say how many round trips an operation made
    rather than how long it took. *)
module Outage (_ : Backend_lwt.Store) : sig
  include Backend_lwt.Store

  val set_up : bool -> unit
  val calls : unit -> int
  val reset : unit -> unit
end

(** [Real] behind a link that refuses: the next [n] requests fail, transiently
    unless [with_] says otherwise, and the rest go through. [on] names the one
    call refused, ["put_if_absent"] say, leaving every other through. Where
    {!Outage} is a request that waits, this is one that comes back failed, which
    is what a queue's retries and parking are for. *)
module Flaky (_ : Backend_lwt.Store) : sig
  include Backend_lwt.Store

  val refuse_next : ?on:string -> ?with_:exn -> int -> unit
  val refusals : unit -> int
end

(** Readable and never writable — a wrong credential, a bucket that refuses
    writes. Reads answer empty rather than failing; writes raise
    {!Backend.Not_writable}. *)
module Refuses : Backend_lwt.Store

(** The slice a range read answers with, for a double that holds whole bodies:
    clamped at the end of the object as every driver's is, so a double cannot
    answer a range a real store would have cut short. *)
val range_of : offset:int -> length:int -> Bigstring.t -> Bigstring.t
