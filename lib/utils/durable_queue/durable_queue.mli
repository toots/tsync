(** Work that has to happen, kept on disk until it does.

    A record is written before the caller is told its own operation is done, so
    a crash leaves something saying what is still owed. Nothing here knows what
    a job {i is}: the owner supplies {!JOB} and the function that runs one.

    Two things sit here, because the durable record outlives the queue that
    drains it:

    - {!Make.Records} — the records themselves, usable on their own by work done
      synchronously that only needs to survive a crash, and read by whatever
      reconciles or reports on what is outstanding.
    - {!Make.t} — a worker draining that log, either {!Make.ordered} or
      {!Make.keyed}; both share the log, the backoff, the poison policy and the
      drain, and differ only in what the work is.

    A queue runs whatever [run] it was handed and so cannot tell a failure that
    will clear from one that will not: [classify] is how the creator, who does
    know, says. Waiting out a permanent failure never ends, and poisoning a
    transient one loses work that would have landed. *)

(** What to do with a job whose failure will not clear.

    Either way the job leaves the queue: the same request would be refused
    again, and everything recorded behind it would wait forever. *)
type poison =
  | Stop
      (** Leave the record on disk. For work something outside the queue is
          expected to reconcile or report, so dropping it would strand what it
          names. *)
  | Drop
      (** Unlink the record. For a target that can be rebuilt wholesale — the
          queue is marked degraded, which is the state a resync repairs. *)

(** [degraded] means work was dropped or the log overflowed. Unlike being merely
    behind, patience will not fix it. *)
type stats = {
  queued : int;
  in_flight : int;
  degraded : bool;
  bytes : int64;  (** Total {!Make.keyed} weight still owed; [0L] otherwise. *)
}

(** How a job is written to and read back from disk. A body that no longer
    parses reads as [None]: it is logged and discarded, rather than stalling the
    queue at every start. *)
module type JOB = sig
  type t

  val to_string : t -> string
  val of_string : string -> t option
end

(** The calls this makes of a filesystem, spelled as {!Fs} spells them so that
    one can be handed over as it stands. *)
module type FILES = sig
  type 'a io

  val mkdir_p : string -> unit io
  val atomic_write : string -> string -> unit io
  val readdir_list : string -> string list io
  val readdir_list_quiet : string -> string list io
  val unlink_quiet : string -> unit io
  val is_directory : string -> bool io

  (** [`Gone] for a path that is not there and [`Failed] for one that is but
      could not be read: the first is ordinary on a queue that is working, and
      the second must leave the record where it is. *)
  val read_file : string -> [ `Body of string | `Gone | `Failed of exn ] io
end

(** Give up this process's claim on a log directory. The kernel does this when
    the holder exits, so this is for a caller standing in for that exit. *)
val release : string -> unit

(** How long a started queue may hold jobs without finishing one before it says
    so at [warn]. A queue that has gone quiet neither raises nor returns nor
    logs, so what is reported is the absence. Settable so a test need not wait
    the default minute. *)
val set_stall_warning_interval : float -> unit

module Make
    (Io : Io.S)
    (Clock : Clock.S with type 'a io := 'a Io.t)
    (Lock : Lock.S with type 'a io := 'a Io.t)
    (Files : FILES with type 'a io := 'a Io.t) : sig
  (** Wait for every queue in this process to catch up.

      Stops waiting on a queue that has started failing, and on everything after
      [timeout]: what is left is on disk and resumes on the next start, so
      holding a command open for a store that is down buys nothing. *)
  val settle_all : ?timeout:float -> unit -> unit Io.t

  (** Also wait for this, under the same [timeout]. For background work a
      queue's owner runs beside it without recording: not owed, but still in
      flight, and a caller that has waited for quiet should not have it land
      afterwards. *)
  val register_settle : (unit -> unit Io.t) -> unit

  (** Have every recovering queue in this process look at its log again.

      A one-shot command exits with whatever it could not finish inside its
      settle timeout still on disk, and a daemon that read its log at startup
      would carry those until it restarts. Each queue reads only a log no live
      process claims, so records another process is running from memory are left
      to it. *)
  val rescan_all : unit -> unit Io.t

  module Make (J : JOB) : sig
    (** {1 The records} *)

    module Records : sig
      type t

      (** [dir] should be per target and per domain: the records name one
          target's work, and a shared directory would replay one domain's
          against another's. *)
      val create : dir:string -> t

      val write : t -> id:string -> J.t -> unit Io.t

      (** Read, transform, write back. A record that is already gone is not an
          error: whatever owns it may have finished first. *)
      val update : t -> string -> (J.t -> J.t) -> unit Io.t

      (** The work is done and the record is no longer owed. *)
      val complete : t -> string -> unit Io.t

      (** Everything on disk, in the order it was recorded.

          [wanted] is asked of each id before its body is opened, so a caller
          that will discard most of what it finds says so here rather than
          after: a sweep over a large backlog is otherwise one open per record,
          all but a few of them wasted. *)
      val list : ?wanted:(string -> bool) -> t -> (string * J.t) list Io.t

      (** Records {!list} discarded for being unreadable: work this log's owner
          owes that no replay puts back, which is what a mirror repairs. Counted
          on the log rather than returned, since the reader that discards one
          need not be the one that reports on it. *)
      val dropped : t -> int
    end

    (** {1 Draining it} *)

    type t

    (** One worker, jobs in the order recorded. A job stays at the head until it
        is taken, so a failure that can clear is waited out rather than losing
        the write and letting what follows overtake it. *)
    val ordered :
      ?max_queued:int ->
      name:string ->
      log:Records.t ->
      classify:(exn -> Retry.kind) ->
      poison:poison ->
      run:(J.t -> unit Io.t) ->
      unit ->
      t

    (** [workers] jobs at once, at most one per [key]: posting a job whose key
        is already busy cancels the running one and takes its place, so a file
        rewritten while its upload is in flight uploads once, from the newer
        bytes ([run] is handed the flag to poll for that).

        A transient failure requeues at the back rather than the head, holding
        the head being what would stall every other key behind one that is
        failing; [weight] is what {!stats.bytes} sums. *)
    val keyed :
      ?max_queued:int ->
      ?workers:int ->
      ?weight:(J.t -> int64) ->
      name:string ->
      log:Records.t ->
      key:(J.t -> string) ->
      classify:(exn -> Retry.kind) ->
      poison:poison ->
      run:(id:string -> J.t -> cancel:bool ref -> unit Io.t) ->
      unit ->
      t

    (** Record [job], then queue it. Returns once it is durable, not once it has
        run — that is the point. *)
    val post : ?id:string -> t -> J.t -> unit Io.t

    (** Run the workers.

        [recover] reads the log first, and again on every {!rescan_all}, so work
        a process left behind is picked up without waiting for a restart.
        Without it the log is never read and this queue's records are only ever
        its own, which is what a one-shot command wants: it claims the directory
        for as long as it lives, and a recovering queue elsewhere leaves it
        alone until it exits. *)
    val start : ?recover:bool -> t -> unit

    (** Cancel the job running or queued under [key], and drop any replacement
        waiting behind it. [false] when nothing is owed for that key. Only
        meaningful for {!keyed}. *)
    val cancel : t -> string -> bool

    (** Hold the workers without losing what is queued. A stop still drains. *)
    val set_paused : t -> bool -> unit

    val paused : t -> bool

    (** Stop the workers and wait for them, leaving anything unstarted on disk.
    *)
    val stop : t -> unit Io.t

    val stats : t -> stats

    (** The jobs a worker is running right now. The jobs themselves, not their
        keys: a caller wanting the key derives it the way it was derived to post
        them, rather than taking a rendered one back apart. *)
    val in_flight : t -> J.t list

    (** Distinct keys still owed, running or queued. *)
    val owed : t -> int
  end
end
