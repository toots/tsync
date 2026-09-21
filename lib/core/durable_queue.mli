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

include module type of struct
  include Durable_queue_intf
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
    (Files : FILES with type 'a io := 'a Io.t) : S with type 'a io := 'a Io.t
