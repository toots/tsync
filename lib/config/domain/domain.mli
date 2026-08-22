(** A parsed config, made live: the domain a command or a daemon actually runs
    against.

    {!Conf_parsing} reads the file and {!Conf.S} is the shape everything above
    is a functor over; this is the step between, and the one place a configured
    role becomes behaviour — which store is the source of truth, which is a copy
    filled behind the write, which is only ever read.

    [paths] is asked for rather than discovered here: where a machine keeps its
    cache and data is the caller's to decide, and a library reading the
    environment at load could not be pointed elsewhere by a test.

    {!of_config} builds the domain [cfg] describes, with its stores built and
    its members described. [domain] names which one, falling back to
    {!default_domain} and then to the sole configured domain; [socket_path]
    overrides where its daemon answers. [resume] picks up the deferred work a
    previous run left owed and belongs to the daemon alone — a one-shot command
    records and drains its own, but must not run jobs the daemon is also
    running. *)
val of_config :
  ?domain:string ->
  ?socket_path:string ->
  ?resume:bool ->
  paths:Runtime.paths ->
  Conf_parsing.t ->
  (module Conf.S)

(** Read from the member named, and only read: writes still go through the
    domain's own path so the deferred targets behind it still fill. Raises
    [Failure] when nothing has that name, or when several do. *)
val reading_from : string -> (module Conf.S) -> (module Conf.S)

(** The domain a command means and the socket its daemon answers on. *)
val target :
  ?domain:string -> paths:Runtime.paths -> Conf_parsing.t -> string * string

(** The domain to use when a command names none. [None] when nothing is
    recorded, or when the name recorded is not a configured domain — dropping a
    domain from the config must not break every command that omits [--domain].
*)
val default_domain : paths:Runtime.paths -> string option

(** Where that name is kept, for the command that writes it. *)
val default_domain_file : paths:Runtime.paths -> string
