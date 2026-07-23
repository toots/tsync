(* http-proxy is portable (always compiled in); register it unconditionally.
   Forced into the link by tsync_frontend's -linkall. *)
let () = Http_proxy_frontend.register ()
