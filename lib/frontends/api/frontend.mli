(** What a frontend is, and the process it runs in.

    A frontend is one way of presenting a domain to a user — a mounted
    filesystem, a macOS File Provider, an HTTP server. Each registers itself
    from its own initialiser and is kept in the link by [-linkall], so adding
    one is a matter of linking its library. *)

(** One domain's binding: the domain conf, this frontend's options (from the
    config's [frontend_config.options]), and the mount point, which only fuse
    uses. *)
type binding = {
  conf : (module Conf.S);
  options : (string * string) list;
  mount_point : string;
}

(** How a frontend lets a user see a change some other client made.

    Every frontend needs an answer, and the answer differs by what the
    presentation layer underneath it can be told. Required rather than optional
    because a frontend with no answer looks like one that simply has nothing to
    do: the mount keeps serving names that no longer resolve, and nothing
    reports it. That is how the FUSE mount came to show a file under its name
    from before another client renamed it, unopenable, until the mount was taken
    down.

    A frontend picks the one that is true of it, not the one that is convenient. *)
type freshness =
  | Notify of (string -> unit)
      (** Hand each changed key to the presentation layer as it happens, for a
          layer that keeps its own state and has to be told. macOS File Provider
          works this way. *)
  | Revalidates
      (** Nothing has to be pushed, because the layer asks again on every access.
          A claim to earn: FUSE says this only because it mounts with the
          kernel's caches disabled, which is what makes the kernel re-ask. *)

module type S = sig
  (** Whether every byte of [key] is on this machine, for [tsync ls]. *)
  val is_local : Conf.locality -> string -> bool

  (** Serve every binding. Blocks until shutdown. *)
  val start : binding list -> unit
end

(** {1 Registry} *)

(** A CLI subcommand a frontend contributes, surfaced as
    [tsync <cli_group> <verb>]. Declarative and cmdliner-free, like
    {!field_spec}: the binary parses the arguments and resolves [--domain] to a
    {!Conf.S}, checking this frontend is configured for that domain, before
    calling [run]. *)
type command = { verb : string; doc : string; run : (module Conf.S) -> unit }

(** [spec] is what [tsync configure] prompts for; see {!Field_spec}, which a
    backend declares its settings with too. [cli_group] defaults to [name]. *)
val register :
  ?spec:Field_spec.t list ->
  ?cli_group:string ->
  ?commands:command list ->
  string ->
  (module S) ->
  unit

val find : string -> (module S) option
val spec_for : string -> Field_spec.t list

(** Every registered frontend name. What is available depends on how the binary
    was linked. *)
val names : unit -> string list

(** Name, CLI group and contributed commands, per registered frontend. *)
val entries : unit -> (string * string * command list) list

(** {1 The process a frontend runs in}

    A frontend takes over a process: it picks the event loop, sizes the blocking
    thread pool, and forks one child per group of domains. *)

(** Select the libev event loop and cap the blocking pool. Call from inside the
    leaf's own Lwt loop, after all forking: the first [Lwt_unix] touch creates
    the notification eventfd, and a child inheriting a shared one loses its
    worker-completion wakeups.

    Raises [Failure] when lwt was built without libev. Never Lwt's default
    [select] engine: it cannot watch a descriptor numbered at or above
    FD_SETSIZE — 1024 on macOS — so once {!Descriptors} lifts the process limit
    past that, one high-numbered descriptor raises EINVAL out of [select] and
    takes the whole event loop down. That is strictly worse than the EMFILE the
    higher limit exists to prevent: EMFILE fails one accept, EINVAL fails
    everything. Checked rather than assumed, because [conf-libev] being
    installed only means the C library is present — lwt built while it was
    absent silently falls back to [select]. *)
val cap_blocking_pool : unit -> unit

(** Narrow that ceiling to what the storage absorbs, once something has asked
    it. The default is a burst ceiling, not a statement about any device: an
    enclosure taking one command at a time exhausts the block layer's queue tags
    long before the threads help, and threads past what the device takes are a
    queue in the wrong place. The floor keeps a slow device from making the
    process unresponsive rather than merely unhurried. *)
val size_blocking_pool : concurrency:int -> unit

(** Run [f] on every item, each in its own child process except the last, which
    runs here and blocks — a frontend's [start] blocks. On return, SIGTERM and
    reap the children.

    Forks with [Lwt_unix.fork], not [Unix.fork]: Lwt's notification eventfd is
    created at module init, so a plain fork leaves parent and child sharing one
    and the child's worker wakeups go to the wrong process. *)
val run_forked : ('a -> unit) -> 'a list -> unit
