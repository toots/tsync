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

(** [$TSYNC_CONFIG_JSON] when set, else the config file; [None] when absent. A
    config file readable by group or other is refused (DENIED), or, when
    [interactive] (by default, when stderr is a terminal), made private with a
    warning. *)
val read_config : ?interactive:bool -> unit -> string option

val default_domain : unit -> string option

(** 07 §2.7: the file the service writes its log to, [None] where the system
    journal holds it (Linux). *)
val service_log : unit -> string option

(** The host's claim on its App Group container (file-provider §3.1), run once
    by the program before anything touches the container; a no-op on hosts
    without one. *)
val claim_group : unit -> unit

(** At module initialisation, by the host's library. *)
val set_group_claim : (unit -> unit) -> unit
