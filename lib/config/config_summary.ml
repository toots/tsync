let feature = function
  | "passwords" -> Some "Passwords"
  | "totp" -> Some "Two-factor codes"
  | _ -> None

let backend (b : Config.backend) =
  let where =
    match Config.fstr b.fields "url" with Some url -> url | None -> b.bname
  in
  (match b.role with
    | Main -> "  Stored at: "
    | Replica | Backfill -> "  Copied to: "
    | Read_only -> "  Read from: ")
  ^ where

let domain (d : Config.domain) =
  let also = List.filter_map feature (Option.value ~default:[] d.extensions) in
  String.concat "\n"
    (Tsync_core.Domain_name.to_string d.name
     :: Option.fold ~none:[]
          ~some:(fun at -> ["  Folder: " ^ at])
          (Mounts.configured d)
    @ List.map backend d.backends
    @ (if also = [] then [] else ["  Also: " ^ String.concat ", " also])
    @ if d.read_only then ["  Read only"] else [])

let render (config : Config.t) =
  match config.domains with
    | [] -> "No domains are set up."
    | domains -> String.concat "\n\n" (List.map domain domains)
