(** The status report: what this process is doing, and what each domain's
    backends look like from here.

    Assembled as JSON so a frontend can serve it and the CLI can print it, with
    {!text} the one renderer — a report gets pasted into bug threads, so there
    is exactly one layout to recognise. Every backend is probed under a
    deadline: an unreachable store must make the report late, not absent. *)

(** This process: uptime, CPU, GC and Lwt counters. [extra] is merged in for a
    caller with something to add — the http proxy reports its listener. *)
val self_json :
  ?extra:(string * Yojson.Safe.t) list -> unit -> (string * Yojson.Safe.t) list

module Make (C : Conf.S) : sig
  (** One domain: its config, cache, pending work, and every backend with its
      role and reachability.

      [totals] counts what each store holds, which is a full listing — [exact]
      counts every shard rather than sampling one and scaling, and [reload]
      recounts instead of answering from the last count. All three default to
      off, so the cheap report is the one a caller gets without thinking about
      it. *)
  val domain_json :
    ?totals:bool ->
    ?exact:bool ->
    ?reload:bool ->
    ?extra:(string * Yojson.Safe.t) list ->
    ?frontends:Yojson.Safe.t list ->
    unit ->
    Yojson.Safe.t Lwt.t
end

(** Fold reports from one process into a single report: the domains are
    concatenated, the jobs concatenated and deduplicated by pid, everything else
    taken from the first. For a caller that had to ask a multi-domain daemon
    once per domain — where one process answers for several, each answer carries
    that process's whole job table. *)
val merge : Yojson.Safe.t list -> Yojson.Safe.t

(** Render a report for a human. *)
val text : Yojson.Safe.t -> string
