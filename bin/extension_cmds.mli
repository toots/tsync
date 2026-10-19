(** The CLI's view of extension domains (extensions README §6.1). *)

val dname : Tsync_config.Config.domain -> string

(** The domains that may use [extension]: listing it, or following their main.
*)
val using :
  extension:string -> Tsync_config.Config.t -> Tsync_config.Config.domain list

(** Where a new record goes: [--domain], else the only candidate, else the
    default domain when it is one. *)
val write_domain :
  ?name:string ->
  extension:string ->
  Tsync_config.Config.t ->
  Tsync_config.Config.domain

(** [f] on every candidate domain; refused only when none answered. *)
val each :
  ?name:string ->
  extension:string ->
  Tsync_config.Config.t ->
  (Tsync_config.Config.domain -> 'a) ->
  (Tsync_config.Config.domain * 'a) list

(** A verb taking [--domain] and [-v]. *)
val verb :
  string ->
  doc:string ->
  (?name:string -> Tsync_config.Config.t -> int) Cmdliner.Term.t ->
  int Cmdliner.Cmd.t
