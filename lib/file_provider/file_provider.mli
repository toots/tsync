type context

val auto_evict : bool ref
val set_pending_version : string -> unit

val make_context :
  store:File_store.t ->
  files:File.store ->
  domain_name:string ->
  domain_prefix:string ->
  mount_point:string ->
  context

val mount : context -> string array -> unit
