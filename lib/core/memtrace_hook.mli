(** Allocation tracing with memtrace, for finding memory leaks.

    When [$TSYNC_MEMTRACE_DIR] is set, the process writes a memtrace trace to
    [<dir>/tsync-<pid>-<start time>.ctf], sampling at [$TSYNC_MEMTRACE_RATE]
    (default [1e-5]). The trace's context is the process's role, such as
    ["owner Files"]. A build without the memtrace library ignores both
    variables. *)

(** Start tracing if requested. Called once per process, before the runtime
    starts its domains, so that every domain is sampled. *)
val start : unit -> unit

(** Finish the trace. memtrace finishes it at exit; a process that ends with
    [Unix._exit], which skips [at_exit], calls this first. *)
val stop : unit -> unit
