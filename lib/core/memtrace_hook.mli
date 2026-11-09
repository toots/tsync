(** Allocation tracing with memtrace, for finding memory leaks.

    When [$TSYNC_MEMTRACE_DIR] is set, the process writes a memtrace trace to
    [<dir>/tsync-<pid>.ctf], sampling at [$TSYNC_MEMTRACE_RATE] (default
    [1e-5]). The trace's context is the process's command line. A build without
    the memtrace library ignores both variables. *)

(** Start tracing if requested. Called once per process, before the runtime
    starts its domains, so that every domain is sampled. *)
val start : unit -> unit
