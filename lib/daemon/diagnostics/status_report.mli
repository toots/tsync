(** Asking the processes beside this one, and folding what they say into the one
    report a reader sees.

    {!Diagnostics} answers for a single process; this assembles. The split
    matters because only a collector may fan out: a frontend asked for its
    figures must answer about itself and ask nobody, or a collector asking it
    would square the fan-out. *)

(** The [arg] flag that says so. Travels in the same comma-separated set as
    [totals]/[exact]/[reload]. *)
val frontend_only : string

type answer = {
  domain : string;
  frontend : string;
  socket_path : string;
  reply : Yojson.Safe.t;
}

(** [ask ~frontend ~domain ~socket_path ()] puts the [stats] question to one
    daemon. Never raises: a socket that does not answer comes back as an answer
    saying so, since a report exists to show what is wrong.

    [frontend] is the name the caller expects to find there, used to say which
    frontend is silent when one is; [""] when the caller does not know. *)
val ask :
  ?timeout:float ->
  ?arg:string ->
  frontend:string ->
  domain:string ->
  socket_path:string ->
  unit ->
  answer Lwt.t

(** The entry this answer contributes to its domain's [frontends]: what only
    that frontend knows, plus the pid, uptime, cpu and traffic that place it —
    counted per process, so the asker cannot see them for itself. *)
val frontend_entry : answer -> Yojson.Safe.t

(** Every answer folded into the one report a reader sees:
    [{host, domains, processes, jobs, warnings}].

    [local] is the collector's own {!Diagnostics.self_json} and [domains] the
    domain bodies it computed itself — the launcher's, or a one-shot command's.
    A collector that computed none passes neither, and the bodies come from the
    answers instead; that is the whole difference between asking the process
    that owns the domains and asking each frontend in turn, so there is one fold
    and not two.

    Processes and jobs are deduplicated by pid, a domain's frontends by the
    process they name, and warnings by message — the same failure is logged by
    everyone who saw it and once per retry besides. *)
val of_answers :
  ?local:(string * Yojson.Safe.t) list ->
  ?domains:Yojson.Safe.t list ->
  answer list ->
  Yojson.Safe.t

(** Render a report for a human. The one renderer, so a browser, [curl] and
    [tsync status] cannot disagree. *)
val text : Yojson.Safe.t -> string
