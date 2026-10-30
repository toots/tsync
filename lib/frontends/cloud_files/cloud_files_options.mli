(** The [cloud_files] frontend's descriptor and options (cloud-files §6).
    Registers itself when linked. *)

(** The folder presented: [syncRoot], else [%USERPROFILE%\tsync\<domain>]. *)
val sync_root : Tsync_config.Config.domain -> string
