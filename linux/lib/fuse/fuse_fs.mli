type context = Context.t

val auto_evict : bool ref
val set_pending_version : string -> unit
val mount : context -> string array -> unit
val path_to_key : context -> string -> string
val key_to_abs_path : context -> string -> string
