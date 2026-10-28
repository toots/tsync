(* macOS registers its keychain and reports a screen lock from its host,
   Android from its JNI library and its app; Windows reports a screen lock from
   its session, and Session ignores the hook elsewhere. *)
let register () = Tsync_core.Session.on_lock Tsync_owner.Owner.screen_locked
let register_verifier () = ()
