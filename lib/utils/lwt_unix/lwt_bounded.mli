(** Running only so much at once.

    [Lwt_list.iter_p] and friends start every element at once, which is right
    for a list whose length the code chooses — a chunk group's two members — and
    wrong for one whose length a caller chooses: the chunks in a file, the
    entries in a directory.

    Such a fan-out usually {i is} bounded somewhere, but the bound often governs
    a different resource than the one that runs out: a whole-file fetch bounded
    to [max_downloads] still opened each destination before queueing for a slot,
    so a 250 MB file held 247 descriptors against a limit of 256.

    Two rules follow:

    - A fan-out over a caller-sized list bounds itself here rather than relying
      on something downstream.
    - The slot is taken before the resource, never after. *)

(** {1 A bound that outlives one fan-out}

    For a budget shared across calls — uploads in flight for a domain, downloads
    for a store — where the limit belongs to the resource rather than to any one
    caller. *)

type t

(** [create ~max ()] admits [max] jobs at once ([max] below one is treated as
    one) and queues the rest.

    [max_waiting] caps that queue. Unbounded, it turns a busy resource into a
    growing list of promises whose callers time out with nothing to say why;
    capped, {!use_or} refuses instead, which is how a client is told to slow
    down.

    [name] registers the pool so it can be reported on. Name the ones that stand
    for a scarce resource — a per-call pool is not one, and an unnamed pool is
    simply left out. *)
val create : ?max_waiting:int -> ?name:string -> max:int -> unit -> t

(** Run [f] under [t], waiting for a slot. Raises {!Busy} if [t] has a
    [max_waiting] and its queue is full. *)
val use : t -> (unit -> 'a Lwt.t) -> 'a Lwt.t

(** Raised by {!use} when the queue is full. *)
exception Busy

(** [use_or t ~busy f] is {!use} answering with [busy ()] rather than raising,
    so a caller can turn a full queue into a refusal its client understands. *)
val use_or : t -> busy:(unit -> 'a Lwt.t) -> (unit -> 'a Lwt.t) -> 'a Lwt.t

(** Jobs running right now. *)
val in_flight : t -> int

(** Jobs holding a queue slot, waiting to start. Above zero means callers are
    waiting on the bound rather than the work. *)
val waiting : t -> int

(** What [max] was admitted as, so a report can say 4/4 rather than 4. *)
val limit : t -> int

(** Every pool {!create}d with a [name], in creation order. *)
val registered : unit -> (string * t) list

(** {1 Fanning a list out under a bound}

    Both take a {!t} explicitly, and it should outlive the call: a bound stands
    for a resource — a device's queue depth, a connection budget — and a
    resource belongs to the process, so one created per invocation only looks
    like a bound. Where fairness matters, use a separate {!t} per class of work.

    A shared {!t} must be held around the resource and nothing more: held across
    a recursive call, or around work that asks for the same budget, it deadlocks
    with outer jobs holding every slot while inner jobs wait for one. *)

(** [map_with t f xs] runs [f] over [xs] under [t], results in the order of [xs]
    rather than of completion. Fails with the first exception raised, like
    [Lwt_list.map_p]. *)
val map_with : t -> ('a -> 'b Lwt.t) -> 'a list -> 'b list Lwt.t

(** {!map_with} for a fan-out whose results are not wanted. *)
val iter_with : t -> ('a -> unit Lwt.t) -> 'a list -> unit Lwt.t

(** {!map_with} keeping the results that are [Some], in input order. *)
val filter_map_with : t -> ('a -> 'b option Lwt.t) -> 'a list -> 'b list Lwt.t
