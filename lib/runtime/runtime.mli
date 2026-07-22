val implementation : string

type paths = {
  cache_root : string;
  socket_path : string;
  data_dir : string;
  config_path : string;
}

val default_paths : unit -> paths
val pre_start : mount_point:string -> unit
val domain_socket_path : paths -> string -> string

val is_local :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  string ->
  bool

val start : confs:(module Conf.S) list -> mount_fn:(string -> string) -> unit
