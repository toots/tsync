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

(** There is no "committed" state: the record is deleted the moment the entry is
    published, and a crash in that window leaves [Executed], which reconcile
    resolves by asking the backend whether the entry is there. Writing a state
    only to delete it would be a disk write per upload buying nothing. *)
type state =
  | Intent  (** Recorded. Nothing has happened yet. *)
  | Prepared  (** The data is staged locally; the upload is owed. *)
  | Executed  (** The bytes are on the backend; the entry is not published. *)

(** The key is not here: it is the record's id in the log, so one unit of work
    keeps one name from here through the published journal entry to the cursor a
    peer compares against, with nowhere for two spellings to disagree. *)
type record = {
  ops : Journal.op list;
  state : state;
  attempts : int;
  last_error : (Retry.kind * string) option;
      (** Why it last failed, so a stuck record can say so instead of being
          counted. *)
}

(** The job a durable queue drains, for a caller that builds one over these
    records. *)
module Job : Durable_queue.JOB with type t = record

(** What this needs of a durable log: the record half of a queue, and none of
    the draining. *)
module type RECORDS = sig
  type 'a io
  type t

  val create : dir:string -> t
  val write : t -> id:string -> record -> unit io
  val update : t -> string -> (record -> record) -> unit io
  val complete : t -> string -> unit io
  val list : ?wanted:(string -> bool) -> t -> (string * record) list io
end

module type OWED = sig
  type 'a io
  type 'a t

  val create : unit -> 'a t

  (** Hand one over, answering once it has been taken up. Nothing is dropped if
      no one is consuming: the record is already written, so the work is owed
      whether or not anything is draining yet. *)
  val signal : 'a t -> 'a -> unit io

  (** Take them from now on, displacing whoever was. One consumer at a time: a
      second queue over one domain's records must not find the first still
      taking them. *)
  val consume : 'a t -> ('a -> unit io) -> unit

  (** Stop consuming. What is signalled afterwards is written and left. *)
  val idle : 'a t -> unit
end

module type S = sig
  type 'a io
  type records
  type 'a owed

  (** This domain's records. Shared with {!Sync_queue}, which drains the ones
      that name an upload.

      One value per domain however many times this functor is applied: a second
      log over the same directory would keep an id counter of its own. *)
  val log : records

  (** The records written here and not yet taken up by whoever sends them. One
      per domain, for the same reason the log is. *)
  val owed : (Journal.Entry_key.t * record) owed

  (** Write the intent. The caller mints the key and keeps it: every later call
      names the same unit of work. *)
  val record : Journal.Entry_key.t -> Journal.op list -> unit io

  (** Write a whole record, for a caller that has one in hand: work whose staged
      data has already been read says [Prepared] rather than [Intent], and that
      same value is what it goes on to hand to whoever sends it. *)
  val write : Journal.Entry_key.t -> record -> unit io

  val advance : Journal.Entry_key.t -> state -> unit io

  (** Carry a record through to done, the work it names having happened:
      [Executed], then the entry published, then the cursor moved, then the
      record dropped. A crash in any of those windows leaves a record reconcile
      can finish from what the backend says.

      [publish] and [cursor] are the store's, and the caller's to choose: one
      discharging a single operation in its own path moves the cursor there and
      then, while one draining a queue records it and lets a busy run collapse
      them. *)
  val discharge :
    publish:(Journal.Entry_key.t -> Journal.op list -> Journal.Entry_key.t io) ->
    cursor:(Journal.Entry_key.t -> unit io) ->
    Journal.Entry_key.t ->
    Journal.op list ->
    unit io

  (** Count the attempt and remember why. Does not change the state: a failure
      leaves the work where it was. *)
  val note_failure : Journal.Entry_key.t -> Retry.kind -> string -> unit io

  (** The work is done or abandoned; drop the record. *)
  val complete : Journal.Entry_key.t -> unit io

  (** This client's records, in {!Journal.Entry_key.compare} order — the order
      the ops must be replayed in. Other clients' records, if a shared data
      directory ever holds any, are left alone. *)
  val list : unit -> (Journal.Entry_key.t * record) list io
end

(** The shape a consumer takes: the hand-off, and {!S} for whichever domain it
    is applied to. *)
module type OVER = sig
  type 'a io
  type records

  module Owed : OWED with type 'a io := 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) :
    S
      with type 'a io := 'a io
       and type records := records
       and type 'a owed := 'a Owed.t
end

module Make (Io : Io.S) (R : RECORDS with type 'a io := 'a Io.t) :
  OVER with type 'a io := 'a Io.t and type records = R.t
