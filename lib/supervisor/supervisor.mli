(** The machine's supervisor (spec 07 §3.1, §3.3, §3.4, §4.4): starts one owner
    process per owner assignment, restarts them, stops them together, and
    answers the supervisor socket. It owns no domain state. *)

type child = {
  args : string list;  (** after the binary *)
  domains : string list;
  socket : string;  (** the owner socket it serves *)
}

(** 07 §2.4: a per-domain presenting frontend or none gets a process of its own,
    shared presenting frontends one process for all their domains, and the
    domains listing [http-proxy] one store server. *)
val assign : ?mount:string -> ?tls:string -> Tsync_config.Config.t -> child list

(** Start [children], restart each one that exits, until the process stop; then
    stop them (07 §3.3, §3.4). The macOS service keeps its store server this way
    without a supervisor. *)
val keep_running : exe:string -> child list -> unit

(** Serve until stopped, as the uplink governor owner, then stop the children
    and answer the exit status: 0, 1 when another supervisor answers, 2 when the
    socket cannot be bound. *)
val run : exe:string -> Tsync_config.Config.t -> child list -> int
