external is_dataless : string -> bool = "caml_is_dataless"

(** Absolute path of that folder, or [None] while the domain is unregistered. *)
val domain_dir : domain_name:string -> string option

(** Serve every domain from one socket, routing each request to the domain it
    names. All of them share one event registry, so a client subscribes per
    domain over the same socket it asks questions on. *)
val start : served:Frontend.served list -> socket_path:string -> unit
