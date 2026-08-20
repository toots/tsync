(** What a frontend is, and the process it runs in.

    A frontend is one way of presenting a domain to a user — a mounted
    filesystem, a macOS File Provider, an HTTP server. Each exposes a [register]
    that lib/frontends calls, one line per frontend, so which ones a binary has
    is a question the source answers. *)

(** One domain's binding: the domain conf, this frontend's options (from the
    config's [frontend_config.options]), and the mount point, which only fuse
    uses. *)
type binding = {
  conf : (module Conf.S);
  options : (string * string) list;
  mount_point : string;
}

(** How many processes a frontend needs. Declared, not enacted: the launcher
    does the forking, so one place decides what runs where.
    [`Process_per_binding] is for a frontend whose serving call blocks per
    domain, as FUSE's mount does; [`Not_a_daemon] for one driven by commands
    rather than by [tsync start], which the launcher refuses before forking
    anything else. *)
type topology = [ `One_process | `Process_per_binding | `Not_a_daemon ]

(** A binding with the domain wiring the launcher built for it. The lifecycle
    around that wiring is the launcher's, so there is nothing here to start or
    stop and no way to tell whether this process is the one keeping the domain
    fresh. *)
type served = { binding : binding; domain : (module Domain_engine.Domain) }

(** Which socket this frontend answers requests on, or [None] for one that
    answers none. Whether a kind is per domain or shared across them is the
    platform's answer rather than this one's — see
    {!Runtime.domain_socket_path}, which returns one path per domain on Linux
    and the same path for every domain on macOS. *)
type socket = [ `Domain_socket | `Proxy_socket ]

module type S = sig
  (** Whether every byte of [key] is on this machine, for [tsync ls]. *)
  val is_local : Conf.locality -> string -> bool

  val topology : topology
  val listens : socket option

  (** Serve everything handed to this process. Blocks until shutdown. *)
  val start : served list -> unit
end

(** {1 Registry} *)

(** A CLI subcommand a frontend contributes, surfaced as
    [tsync <cli_group> <verb>]. The binary parses the arguments and resolves
    [--domain] to a {!Conf.S}, checking this frontend is configured for that
    domain, before calling [run] with whatever positional arguments followed the
    verb.

    The binary does not interpret those arguments: teaching {!Cmdliner} every
    frontend's flags would put each one's argument grammar somewhere the
    frontend that owns it cannot see. *)
type command = {
  verb : string;
  doc : string;
  run : (module Conf.S) -> string list -> unit;
}

(** [cli_group] defaults to [name]. [spec] is what [tsync config --edit] prompts
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

    The launcher does this: it forks per frontend and per {!topology}, picks the
    event loop and sizes the blocking pool, which is why it can size a leaf
    knowing everything that shares it. Only {!size_blocking_pool} is a
    frontend's, for one that learns a better figure at runtime.

    These live here rather than beside the launcher because {!cap_blocking_pool}
    and {!size_blocking_pool} share the size they last set; splitting them
    across libraries would leave the narrowing silently reporting nothing. They
    belong in a module of their own, which neither the registry nor a frontend
    needs to depend on. *)

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
