(** What one process can say about itself and the domains it holds.

    Assembled as JSON so a frontend can serve it and the CLI can print it.
    {!Status_report} is the other half — asking the processes beside this one
    and folding the answers into the report a reader sees. Every backend is
    probed under a deadline: an unreachable store must make the report late, not
    absent. *)

(** Start this process's clock again. For a forked child: the module-level stamp
    {!self_json} reports was taken in the parent, so without this every frontend
    the launcher forks reports the launcher's uptime. *)
val restart : unit -> unit

(** This process: uptime, CPU, GC and Lwt counters. [extra] is merged in for a
    caller with something to add — the http proxy reports its listener. *)
val self_json :
  ?extra:(string * Yojson.Safe.t) list -> unit -> (string * Yojson.Safe.t) list

module Make (C : Conf_lwt.S) : sig
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
