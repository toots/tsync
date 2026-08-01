(** Running only so much at once.

    [Lwt_list.iter_p] and friends start every element at once. That is right for
    a list whose length the code chooses — a chunk group's two members, a
    domain's three backends — and wrong for one whose length a caller chooses:
    the chunks in a file, the entries in a directory, the groups in a transfer.
    There the fan-out is as wide as the input, and the input has no limit.

    The failure this exists to prevent is subtler than "too many at once",
    because such a fan-out usually *is* bounded somewhere — and the bound
    governs a different resource than the one that runs out. A whole-file fetch
    was bounded to [max_downloads] concurrent downloads, correctly; but each
    pending fetch had already opened its destination file before queueing for a
    download slot, so descriptors scaled with the file while transfers stayed
    bounded. A 250 MB file held 247 open files against a limit of 256, and the
    daemon died on its next [accept].

    Two rules follow, and they are the whole point of this module:

    - A fan-out over a caller-sized list bounds itself here, rather than relying
      on something downstream to bound it. A pool that limits one resource says
      nothing about the others a job acquires.
    - The slot is taken before the resource, never after. Reserve-then-acquire
      is safe; acquire-then-reserve is the bug above. *)

(** {1 A bound that outlives one fan-out}

    For a budget shared across calls — uploads in flight for a domain, downloads
    for a store — where the limit belongs to the resource rather than to any one
    caller. *)

type t

(** [create ~max ()] admits [max] jobs at once ([max] below one is treated as
    one) and queues the rest.

    [max_waiting] caps that queue. Without it the queue is unbounded, which
    turns a busy resource into a growing list of promises whose callers time out
    one by one with nothing to say why; with it, {!use_or} can refuse instead,
    which is what lets a client be told to slow down. *)
val create : ?max_waiting:int -> max:int -> unit -> t

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

(** Jobs holding a queue slot, waiting to start. Above zero means the bound, not
    the work, is what callers are waiting on — the number that says a resource
    is the limit, and the one worth reporting. *)
val waiting : t -> int

(** {1 Fanning a list out under a bound}

    Both take a {!t} explicitly, and it should always be one that outlives the
    call — bound at module or instance scope, next to the resource it protects.
    A bound created per invocation limits one fan-out and says nothing about how
    many run at once, so where callers arrive on their own schedule (a listing
    per request, a sweep per status query, a transfer per client) it is not a
    bound at all, only the appearance of one.

    That is not a style preference: a bound stands for a resource — a device's
    queue depth, a connection budget, a memory ceiling — and a resource belongs
    to the process, not to a call. Where fairness is the worry, the answer is a
    separate {!t} per class of work (metadata apart from bulk, so a listing
    never queues behind a transfer) rather than a fresh one per caller.

    The cost of sharing is that a {!t} must be held around the resource and
    nothing more. Holding one across a recursive call, or around work that goes
    on to ask for the same budget, deadlocks: the outer jobs hold every slot
    while the inner jobs wait for one. *)

(** [map_with t f xs] runs [f] over [xs] under [t], results in the order of [xs]
    rather than of completion. Fails with the first exception raised, like
    [Lwt_list.map_p]. *)
val map_with : t -> ('a -> 'b Lwt.t) -> 'a list -> 'b list Lwt.t

(** {!map_with} keeping the results that are [Some], in input order. *)
val filter_map_with : t -> ('a -> 'b option Lwt.t) -> 'a list -> 'b list Lwt.t
