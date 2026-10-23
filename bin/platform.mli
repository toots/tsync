(** Registers what this platform gives the owner command (spec security-model
    §10.6): its vault keystore, and the session lock an auto-lock policy
    watches, reported to {!Tsync_owner.Owner.screen_locked}. *)
val register : unit -> unit
