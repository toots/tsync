(** Registers what this platform gives the owner command (spec security-model
    §10.6): its vault keystore, and the session lock an auto-lock policy
    watches, reported to {!Tsync_owner.Owner.screen_locked}. *)
val register : unit -> unit

(** Registers the user verifier the browser host's [verify] calls
    (passwords/linux §4): polkit on Linux; macOS registers LocalAuthentication
    itself. *)
val register_verifier : unit -> unit
