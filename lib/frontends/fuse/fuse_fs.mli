module Make (C : Conf.S) : sig
  val mount : ?allow_other:bool -> string -> unit
end
