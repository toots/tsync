external is_dataless : string -> bool = "caml_is_dataless"

(** Absolute path of that folder, or [None] while the domain is unregistered. *)
val domain_dir : domain_name:string -> string option

(** Serve every domain in [confs] from one socket, routing each request to the
    domain it names. All of them share one event registry, so a client
    subscribes per domain over the same socket it asks questions on. *)
val start : confs:(module Conf.S) list -> socket_path:string -> unit
