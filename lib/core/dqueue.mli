(** Durable queues (spec durable-queue §4): a log is a directory with one file
    per record, named by an id that sorts in creation order; runners drive the
    records of a log to an outcome.

    Only the domain's owner runs a log; any other process may only submit a new
    record with {!Records.create} and poke the owner. *)

(** [BACKOFF(n)]: min(300 s, 0.5 s · 2^min(10, n−1)). *)
val backoff : int -> float

val rearm_interval : float
val settle_timeout : float

(** The record-name grammar: [[0-9A-Za-z-]], beginning with a digit. *)
val valid_id : string -> bool

(** [<20-digit µs>-<8-digit seq>-<pid>]. *)
val submission_id : unit -> string

(** The files of one log. *)
module Records : sig
  type t

  (** Opens, creating the directory. *)
  val open_ : string -> t

  val dir : t -> string
  val path : t -> string -> string

  (** Durable create-if-absent under a fresh id ([mint], submission ids by
      default), minting again when the name is taken. *)
  val create : ?mint:(unit -> string) -> t -> string -> string

  (** {!create}, the record held from birth (see {!hold}); it must not be
      rewritten while held, since a rewrite replaces the locked file. *)
  val create_held :
    ?mint:(unit -> string) -> t -> string -> string * Unix.file_descr

  val read : t -> string -> [ `Body of string | `Gone ]

  (** Durable read-modify-write; a record gone meanwhile is left gone. *)
  val update : t -> string -> (string -> string) -> unit

  val replace : t -> string -> string -> unit

  (** Release a record: its work is done. *)
  val complete : t -> string -> unit

  (** Rename an undecodable record to [<id>.bad] or [<id>.bad.<n>]. *)
  val set_aside : t -> string -> unit

  val set_aside_records : t -> string list

  (** Record ids in order; temporaries and set-aside records are skipped. *)
  val list : t -> string list

  (** Re-key atomically: exactly one of the two names exists at every instant.
  *)
  val rekey : t -> string -> string -> unit

  (** Whether a submitter still holds the record's lock. *)
  val is_held : t -> string -> bool

  (** For a submitter: take the record's lock, released when the descriptor
      closes or the process dies. *)
  val hold : t -> string -> Unix.file_descr
end

(** What a queue needs to know of its jobs. *)
type 'job kind = {
  decode : string -> 'job option;  (** [None]: unparseable, set aside *)
  encode : 'job -> string;
  key : 'job -> string option;  (** the key of a keyed queue *)
  note : 'job -> Fail.t -> 'job;  (** record a failure in the job's body *)
  accepts : 'job -> bool;  (** the subset of a shared log this queue runs *)
}

type failure_note = { attempts : int; last : Fail.t }
type 'job t

(** An ordered queue has one worker and retries at the head; a keyed queue runs
    at most one job per key, retries at the tail, and coalesces: a new post
    cancels the running job of its key and replaces its pending one. *)
val create :
  ?workers:int ->
  name:string ->
  ordered:bool ->
  'job kind ->
  Records.t ->
  'job t

(** Load the records on disk in id order and start the workers. [run] raises a
    classified failure; {!Rt.Cancelled} completes the record, {!Stop.Stopping}
    leaves it owed. [rekey] renames an adopted submission. *)
val start :
  ?paused:bool ->
  ?rekey:(string -> string option) ->
  'job t ->
  (string -> 'job -> cancel:bool Atomic.t -> unit) ->
  unit

(** Durable before it returns: the caller may acknowledge. *)
val post : ?mint:(unit -> string) -> 'job t -> 'job -> string

(** Take an existing record into the run order (a no-op when loaded). *)
val adopt : 'job t -> string -> unit

(** Adopt submitted records whose submitter released them. *)
val rescan : ?rekey:(string -> string option) -> 'job t -> unit

(** Re-adopt every parked record; answers how many. *)
val rearm : 'job t -> int

val pause : 'job t -> unit
val resume : 'job t -> unit
val is_paused : 'job t -> bool

(** Records loaded and not parked. *)
val pending : 'job t -> int

val idle : 'job t -> bool
val parked : 'job t -> (string * failure_note) list
val running : 'job t -> string list
val loaded : 'job t -> string list
val completed : 'job t -> int

(** Set the cancel flag of the job running for a key. *)
val cancel_key : 'job t -> string -> unit

(** Return when idle, not started, paused, stopping, when every loaded record is
    parked, or once a failure is noted after the call began; at most [timeout].
*)
val settle : ?timeout:float -> 'job t -> unit
