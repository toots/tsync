external is_dataless : string -> bool = "caml_is_dataless"

(** Whether [dir], a bare "~/Library/CloudStorage" entry name, is the folder
    fileproviderd created for [domain_name]. Matched on letters and digits only:
    the name it derives drops spaces and other path-hostile characters. *)
val is_domain_dir : domain_name:string -> string -> bool

(** Absolute path of that folder, or [None] while the domain is unregistered. *)
val domain_dir : domain_name:string -> string option

module Make (C : Conf.S) : sig
  val mount : string -> unit
end

val start : confs:(module Conf.S) list -> socket_path:string -> unit
