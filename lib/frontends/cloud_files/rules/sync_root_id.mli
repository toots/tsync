(** Sync root identifiers (cloud-files §4.3): the owner registers its domain's
    root under {!id}, and the supervisor releases every root under {!prefix}
    whose domain is no longer configured. *)

(** [sid] is the user's SID in its string form. *)
val id : sid:string -> Tsync_core.Domain_name.t -> string

val prefix : sid:string -> string
