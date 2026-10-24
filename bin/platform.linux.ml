let register () =
  Tsync_secret_service.Secret_service.register ();
  Tsync_logind.Logind.watch ~on_lock:Tsync_owner.Owner.screen_locked

let register_verifier () = Tsync_polkit.Polkit.register ()
