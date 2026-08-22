(** The interactive config editor: [tsync config --edit].

    A program of its own rather than a command's implementation — it prompts,
    loops over menus, reads the driver and frontend registries to know what to
    ask for, shells out to terraform for a store's credentials, and writes the
    file {!Conf_parsing} then reads back.

    It only asks the registries what exists; filling them is the linking
    question, and stays with whoever builds the binary. *)
module type ENV = sig
  val config_path : string

  (** Which domain the menu opens on, when one is recorded. *)
  val default_domain : unit -> string option
end

module Make (_ : ENV) : sig
  (** Edit the config, writing it on the way out. Raises [Failure] with a
      sentence a user can act on, and exits the process rather than returning
      when it refuses to write a file the reader would reject. *)
  val run : unit -> unit
end
