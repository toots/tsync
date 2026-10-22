(** The vault's keystore on Linux (spec security-model §10.6): one Secret
    Service item per entry, reached over the session bus with libdbus loaded at
    run time. No call ever shows a prompt. *)

(** Registers the keystore when libdbus loads and the environment names a
    session bus; otherwise registers nothing, and K stays in memory. Called by
    the owner command as it starts, never at load, so a test linking this
    library does not reach the user's keyring. *)
val register : unit -> unit
