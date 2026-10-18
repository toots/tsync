external lookup : string -> string option = "tsync_group_container_lookup"

let () =
  Tsync_config.Paths.set_group_claim (fun () ->
      ignore (lookup "group.org.feverdreamtv.tsync"))
