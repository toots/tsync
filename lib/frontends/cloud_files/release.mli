(** Releasing a sync root (cloud-files §13.4): what is whole on disk stays as
    plain files, other placeholders go, and the root is unregistered, so its
    folder opens with no provider. Run by the supervisor at start for domains no
    longer configured, and by purge for every root of the user. The root must
    not be connected. *)

val release : id:string -> string -> unit

(** The sync roots registered for this user by tsync, as (id, path). *)
val registered : unit -> (string * string) list

(** At service start (§13.1): releases every root of this user whose domain is
    not configured with [cloud_files]. *)
val at_service_start : Tsync_config.Config.t -> unit
