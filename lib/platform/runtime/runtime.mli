type paths = { cache_root : string; data_dir : string; config_path : string }

val default_paths : unit -> paths

(** Where to reach the daemon serving a domain. Per-domain rather than one path
    on [paths] because there is no one path: a FUSE domain is its own process
    with its own socket, and only macOS has a single daemon behind every domain
    -- which it expresses by answering the same path for each. *)
val domain_socket_path : paths -> string -> string

(** Where to reach the http-proxy listener. Not per domain on either platform:
    one listener process serves every domain configured on it. *)
val proxy_socket_path : paths -> string

(** Restart the background service this platform installs, so it re-reads
    [config_path]. [false] when the service is not installed. *)
val restart_service : unit -> bool

(** Argv reading the daemon's log, wherever this platform's service manager put
    it. Meant to be exec'd, so [~follow] streams. *)
val log_command : follow:bool -> lines:int -> string list
