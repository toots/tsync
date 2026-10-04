let () =
  Callback.register "tsync_mount_points" (fun () ->
      [
        ("/mnt/files", "/run/tsync/tsync-files.sock");
        ("/mnt/files/media", "/run/tsync/tsync-media.sock");
        ("/mnt/spaced name", "/run/tsync/tsync-spaced name.sock");
      ])
