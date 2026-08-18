(** Report to the daemon at [socket_path] every [interval] until {!finish} or
    process exit.

    A one-shot command is otherwise invisible: an import that has been running
    for a day reports nothing a second process can read, and the only way to ask
    what it is doing is [/proc] and guesswork. Reporting is advisory and must
    never be load-bearing: no daemon, a wedged daemon, a socket that vanished
    mid-run — every one of those is silence in [tsync status], never a failure
    in the command.

    [target] is what the command was pointed at, as the person who typed it
    would recognise it: a folder for an import or an export, the backend being
    copied from for a mirror. [counters], [current] and [deferred] are what the
    command supplies; memory, GC, transfer totals, pool saturation, backend
    retries and {!Job_progress} are process-wide and gathered here, so a command
    threads nothing through for those. Every closure is sampled on the reporting
    thread and must not block. *)
val start :
  socket_path:string ->
  domain:string ->
  kind:string ->
  ?target:string ->
  ?interval:float ->
  ?current:(unit -> string option) ->
  ?deferred:(unit -> (int * int * bool) option) ->
  counters:(unit -> (string * int) list) ->
  unit ->
  unit

(** A last report marked done, so a finished job is visible for a while rather
    than vanishing the instant it exits. [error] marks it failed instead, which
    is the only trace a crashed command leaves once its process is gone.

    Returns once the send has been attempted; a failure is swallowed like any
    other, and a second call reports nothing. *)
val finish : ?error:string -> unit -> unit Lwt.t
