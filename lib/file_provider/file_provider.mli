external is_dataless : string -> bool = "caml_is_dataless"

module Make (C : Conf.S) : sig
  val mount : string -> unit
end

val start : confs:(module Conf.S) list -> socket_path:string -> unit
