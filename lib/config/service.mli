(** The service as the platform's service manager knows it (07 §2.7): its
    identifiers and the commands every caller goes through, never a signal to a
    process found by name. *)

(** The launchd label of the macOS service. *)
val label : string

(** The macOS app's bundle identifier. *)
val app_bundle_id : string

(** Run a command and answer its exit status; 127 when it cannot start. *)
val run : string list -> int

(** The per-user agent definition the installer writes (file-provider §11). *)
val agent_definition : unit -> string

(** Launch the app if it is not running; never terminates a process. *)
val launch_app : unit -> bool

(** Restart the service through the service manager, then on macOS launch the
    app; false when the service is not installed. *)
val restart : unit -> bool

(** Stop the macOS service and remove its agent definition, so no later login
    starts a service whose bundle is gone (file-provider §9.4). *)
val remove_agent : unit -> unit
