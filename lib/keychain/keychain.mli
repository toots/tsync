(** The vault keystore of macOS and iOS (spec security-model §10.6): the login
    keychain, or the data-protection keychain on iOS, with every dialog refused.
*)

(** Registers it as the owner's keystore, its items under [service], [name]
    being what status says holds K; on macOS turns keychain dialogs off for the
    process. *)
val register : name:string -> service:string -> unit -> unit
