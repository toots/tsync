(** Running a command that is not a daemon: the event loop it needs, and the
    work it owes on the way out.

    [Lwt_main.run] plus a drain. A command returns as soon as its work is
    posted and a deferred target fills in behind it, so a short-lived process
    that simply exits strands copies for a daemon that may not be running
    alongside it — which is why the drain is here rather than left to each
    caller to remember.

    [report] is a thunk calling [Job.Report.start], run inside the loop so a
    long command reports for as long as it runs, the drain included; that is
    work a caller would otherwise see as a command which had already finished.
    A command that raised still reports, its process being about to go with
    nothing else left to answer for it.

    An exit code belongs outside this: exiting from within the promise would
    skip the drain it exists for. *)
val run : ?report:(unit -> unit) -> 'a Lwt.t -> 'a

(** Start a memory trace for this process when [MEMTRACE] names a directory,
    writing [name.ctf] inside it. Raises [Failure] when it names something that
    is not one.

    One file per process: a daemon's frontends and a command are several, and
    two of them inheriting a single trace fd drop about half their samples into
    a file that still reads clean, neither saying which process allocated. A
    forked child calls this for itself, which is why it is exposed rather than
    left inside {!run}. *)
val trace_process : name:string -> unit
