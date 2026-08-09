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

    Required rather than optional because a frontend with no answer looks like
    one that has nothing to do: that is how the FUSE mount came to serve a file
    under its name from before another client renamed it, unopenable, until the
    mount was taken down.

    A frontend picks the one that is true of it, not the one that is convenient.
*)
type freshness =
  | Notify of (string -> unit)
      (** Hand each changed key to the presentation layer as it happens, for a
          layer that keeps its own state and has to be told. macOS File Provider
          works this way. *)
  | Revalidates
      (** Nothing has to be pushed, because the layer asks again on every
          access. A claim to earn: FUSE says this only because it mounts with
          the kernel's caches disabled, which is what makes the kernel re-ask.
      *)

module type S = sig
  (** Whether every byte of [key] is on this machine, for [tsync ls]. *)
  val is_local : Conf.locality -> string -> bool

  (** Serve every binding. Blocks until shutdown. *)
  val start : binding list -> unit
end

(** {1 Registry} *)

(** A CLI subcommand a frontend contributes, surfaced as
    [tsync <cli_group> <verb>]. The binary parses the arguments and resolves
    [--domain] to a {!Conf.S}, checking this frontend is configured for that
    domain, before calling [run]. *)
type command = { verb : string; doc : string; run : (module Conf.S) -> unit }

(** [cli_group] defaults to [name]. [spec] is what [tsync configure] prompts
    for; see {!Field_spec}. *)
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

    Raises [Failure] when lwt was built without libev, which is checked rather
    than assumed because [conf-libev] being installed only means the C library
    is present. Never Lwt's default [select] engine: it cannot watch a
    descriptor at or above FD_SETSIZE — 1024 on macOS — so once {!Descriptors}
    lifts the process limit past that, one high-numbered descriptor raises
    EINVAL and takes the whole event loop down, which is worse than the EMFILE
    the higher limit exists to prevent.

    [concurrency] is how many blocking operations the domains this process
    serves can have outstanding — {!binding_concurrency} answers it. Asked for
    rather than defaulted because Lwt never returns a pool thread once it grows
    one, so a frontend that does not say sets a memory floor for the life of the
    process rather than a ceiling it might not reach. *)
val cap_blocking_pool : concurrency:int -> unit

(** Narrow that ceiling to what the storage absorbs, once something has asked
    it. Threads past what the device takes are a queue in the wrong place; the
    floor keeps a slow device from making the process unresponsive rather than
    merely unhurried. *)
val size_blocking_pool : concurrency:int -> unit

(** What the domains in these bindings ask of the blocking pool, for
    {!cap_blocking_pool}. *)
val binding_concurrency : binding list -> int

(** Run [f] on every item, each in its own child process except the last, which
    runs here and blocks — a frontend's [start] blocks. On return, SIGTERM and
    reap the children.

    Forks with [Lwt_unix.fork], not [Unix.fork]: Lwt's notification eventfd is
    created at module init, so a plain fork leaves parent and child sharing one
    and the child's worker wakeups go to the wrong process. *)
val run_forked : ('a -> unit) -> 'a list -> unit
