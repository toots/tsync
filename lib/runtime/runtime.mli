type paths = {
  cache_root : string;
  socket_path : string;
  data_dir : string;
  config_path : string;
}

val default_paths : unit -> paths
val domain_socket_path : paths -> string -> string
