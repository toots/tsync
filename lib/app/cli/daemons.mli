(** Which frontend serves a domain, and where the daemon serving it answers.

    The resolution half of what {!Launcher} enacts: both need the whole (domain
    × frontend) matrix, which a frontend cannot see and a command has no
    business re-deriving. Nothing here starts anything.

    {!frontend_for} takes the [frontend] override when given — it must be one
    the domain lists — and the domain's first otherwise. Resolved when called
    rather than at module init, so frontend registration, a link-order side
    effect, has already happened. *)
val frontend_for :
  ?frontend:string -> Conf_parsing.domain -> (module Frontend.S)

(** The frontend type names a domain configures, in config order. *)
val frontend_names : Conf_parsing.domain -> string list

(** The domain a path belongs to and the path within it, or [None] when it sits
    under no domain's root. What a command holding a path a user typed uses to
    name the item before it asks anything of a daemon.

    A relative path is resolved against the working directory. *)
val domain_for_path :
  ?domain:string ->
  paths:Runtime.paths ->
  Conf_parsing.t ->
  string ->
  (Conf_parsing.domain * string) option

(** Every domain on this machine paired with the socket its daemon answers on,
    for a command that reports rather than acts. Asked of each configured
    frontend rather than assumed: a domain served only by a listener has no
    socket of its own, and knocking on one nothing binds reports a daemon down
    that was never up.

    A domain keeps its name even where the socket is shared, that being what the
    macOS daemon routes on. Raises [Failure] when no domain is configured. *)
val all : paths:Runtime.paths -> Conf_parsing.t -> (string * string) list
