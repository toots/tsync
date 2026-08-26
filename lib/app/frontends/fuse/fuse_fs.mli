module Make (_ : Conf_lwt.S) (_ : Domain_engine.Domain) : sig
  val mount : ?allow_other:bool -> string -> unit
end
