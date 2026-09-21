(** This client's intent log: what it set out to do, and how far it got.

    Entirely local. The shared journal on the backend is {!File_store}'s, and
    this module never sees a backend key — which is what lets the same recovery
    run against any store.

    The record, not the staged tree, is the source of truth for a unit of work:
    driving recovery from the staged tree mints a fresh entry key on every
    replay and orphans the record it should have finished, which once left one
    domain with 295 orphans reported as a single opaque number.

    A record is also the durable job {!Sync_queue} drains, so it is a
    {!Durable_queue.JOB} and the log below is the record half of such a queue. A
    metadata operation happens synchronously here rather than through the queue,
    but writes to the same log, so one reconcile and one report see everything
    this client owes. *)

include module type of struct
  include Wal_intf
end

(** A record's puts, which are the upload queue's, and the rest, which are
    metadata. *)
val partition_puts : Journal.op list -> Journal.op list * Journal.op list

(** Whether a record is the metadata queue's: it names no put. *)
val is_metadata : record -> bool

(** The job a durable queue drains, for a caller that builds one over these
    records. *)
module Job : Durable_queue.JOB with type t = record

module Make (Io : Io.S) (R : RECORDS with type 'a io := 'a Io.t) :
  OVER with type 'a io := 'a Io.t and type records = R.t
