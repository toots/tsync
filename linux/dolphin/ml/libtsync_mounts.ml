(* The whole of the C boundary: a name to look up and a function behind it. What
   it answers is Desktop_mounts's business. *)

let () = Callback.register "tsync_mount_points" Desktop_mounts.mount_points
