val implementation : string option

type paths = {
  cache_root : string;
  socket_path : string;
  data_dir : string;
  config_path : string;
}

val default_paths : unit -> paths
val pre_start : mount_point:string -> unit

module Make (C : Conf.S) : sig
  val mount : string -> unit
end
