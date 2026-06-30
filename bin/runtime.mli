val implemented : bool
val auto_evict : bool ref
val set_pending_version : string -> unit
val pre_start : mount_point:string -> unit

type context

val make_context :
  store:File_store.t ->
  files:File.store ->
  domain_name:string ->
  domain_prefix:string ->
  mount_point:string ->
  context

val mount : context -> string array -> unit
