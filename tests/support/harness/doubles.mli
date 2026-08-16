(** Stores that behave badly on purpose.

    Each was written out per test, so the same "a store that is down" existed
    several times over and a new method on {!Backend.S} had to be stubbed into
    every copy. *)

(** Every operation fails with [why], which appears in the report a test prints,
    so two unreachable stores in one domain can be told apart. *)
module Down (M : sig
  val why : string
end) : Backend.S

(** Never answers at all: every operation is a promise that stays pending, for
    the tests whose subject is the answer that does not come. *)
module Hung : Backend.S

(** Readable and never writable — a wrong credential, a bucket that refuses
    writes. Reads answer empty rather than failing; writes raise
    {!Backend.Not_writable}. *)
module Refuses : Backend.S
