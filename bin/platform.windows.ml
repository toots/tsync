let register () =
  Tsync_credential_manager.Credential_manager.register ();
  Tsync_core.Session.on_lock Tsync_owner.Owner.screen_locked

let register_verifier () = ()
