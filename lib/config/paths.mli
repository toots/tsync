(** Runtime paths (spec 07 §2.7): XDG locations on Linux, the App Group
    container on macOS. *)

open Tsync_core

val home : unit -> string
val config_file : unit -> string
val data_dir : unit -> string
val cache_root : unit -> string

(** The macOS service process's one socket for every domain (07 §2.7). *)
val service_socket : unit -> string

(** One socket per owner on Linux; the service process's one socket on macOS. *)
val owner_socket : Domain_name.t -> string

val store_server_socket : unit -> string
val supervisor_socket : unit -> string

(** Locked by the supervisor for as long as it runs. *)
val supervisor_lock : unit -> string

val ownership_lock : Domain_name.t -> string
val default_domain_file : unit -> string

(** [$HOME/tsync/<domain>], the default FUSE mount point. *)
val mount_point : Domain_name.t -> string

(** [$TSYNC_CONFIG_JSON] when set, else the config file; [None] when absent. *)
val read_config : unit -> string option

val default_domain : unit -> string option
