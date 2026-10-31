open Tsync_config

let of_domain (d : Config.domain) =
  let options =
    Option.fold ~none:[]
      ~some:(fun (f : Config.frontend) -> f.options)
      (Config.frontend d "cloud_files")
  in
  match Config.fstr options "syncRoot" with
    | Some p when String.trim p <> "" -> p
    | _ -> Paths.mount_point d.name
