type paths = {
  cache_root : string;
  socket_path : string;
  data_dir : string;
  config_path : string;
}

val default_paths : unit -> paths
val domain_socket_path : paths -> string -> string

(** Restart the background service this platform installs, so it re-reads
    [config_path]. [false] when the service is not installed. *)
val restart_service : unit -> bool

(** Argv reading the daemon's log, wherever this platform's service manager put
    it. Meant to be exec'd, so [~follow] streams. *)
val log_command : follow:bool -> lines:int -> string list
