(** A backend over a directory on this machine.

    Registers itself as ["local"]; {!make} is here for a caller building one
    directly, which is every test that needs a real store without a config. *)

(** [root] is created if missing. *)
val make : root:string -> (module Backend.S)
