let () =
  Callback.register "tsync_mount_points" (fun () ->
      Tsync_config.Mounts.mount_points ())
