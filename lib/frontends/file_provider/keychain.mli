(** The vault keystore of macOS (spec security-model §10.6): the login
    keychain, with every dialog refused. *)

(** Registers it as the owner's keystore, and turns keychain dialogs off for
    the process. *)
val register : unit -> unit
