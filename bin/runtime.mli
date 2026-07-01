val implementation : string

type paths = {
  cache_root : string;
  socket_path : string;
  data_dir : string;
  config_path : string;
}

val default_paths : unit -> paths
val pre_start : mount_point:string -> unit

val is_local :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  string ->
  bool

module Make (C : Conf.S) : sig
  val mount : string -> unit
end
