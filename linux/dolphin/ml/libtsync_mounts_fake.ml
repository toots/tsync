(* Answers the name the plugin looks up, with values the C++ test chose: the
   decode is what that test is about, and the machine's real mounts are not a
   fixture. *)

let () =
  Callback.register "tsync_mount_points" (fun () ->
      [
        ("/mnt/files", "/run/tsync-Files.sock");
        ("/mnt/files/media", "/run/tsync-Media.sock");
        ("/mnt/spaced name", "/run/tsync-Spaced Name.sock");
      ])
