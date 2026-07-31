(* headless is portable (always compiled in); register it unconditionally.
   Forced into the link by tsync_frontend's -linkall. *)
let () = Headless_frontend.register ()
