(** The folder a domain presents (cloud-files §6): [syncRoot], else
    [%USERPROFILE%\tsync\<domain>]. *)

val of_domain : Tsync_config.Config.domain -> string
