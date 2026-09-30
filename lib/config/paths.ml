open Tsync_core

let home () =
  match Sys.getenv_opt "HOME" with
    | Some h when h <> "" -> h
    | _ -> Fail.raise_ Fail.Invalid "HOME is not set"

let env_dir var default =
  match Sys.getenv_opt var with
    | Some d when d <> "" && String.starts_with ~prefix:"/" d -> d
    | _ -> Filename.concat (home ()) default

let macos =
  lazy (try Sys.command "test \"$(uname -s)\" = Darwin" = 0 with _ -> false)

let group () =
  Filename.concat (home ())
    "Library/Group Containers/group.org.feverdreamtv.tsync"

let config_file () =
  if Lazy.force macos then Filename.concat (group ()) "config.json"
  else
    Filename.concat
      (Filename.concat (env_dir "XDG_CONFIG_HOME" ".config") "tsync")
      "config.json"

let data_dir () =
  if Lazy.force macos then Filename.concat (group ()) "tsync"
  else Filename.concat (env_dir "XDG_DATA_HOME" ".local/share") "tsync"

let cache_root () =
  if Lazy.force macos then Filename.concat (data_dir ()) "cache"
  else Filename.concat (env_dir "XDG_CACHE_HOME" ".cache") "tsync"

let owner_socket domain =
  if Lazy.force macos then Filename.concat (data_dir ()) "tsync.sock"
  else
    Filename.concat (data_dir ())
      (Printf.sprintf "tsync-%s.sock" (Domain_name.to_string domain))

let store_server_socket () =
  Filename.concat (data_dir ()) "tsync-http-proxy.sock"

let supervisor_socket () = Filename.concat (data_dir ()) "tsync-sync.sock"

let ownership_lock domain =
  Filename.concat
    (Filename.concat (data_dir ()) "owners")
    (Domain_name.to_string domain ^ ".lock")

let default_domain_file () = Filename.concat (data_dir ()) "default-domain"

let mount_point domain =
  Filename.concat
    (Filename.concat (home ()) "tsync")
    (Domain_name.to_string domain)

let read_config () =
  match Sys.getenv_opt "TSYNC_CONFIG_JSON" with
    | Some text -> Some text
    | None -> Fs.read_file_opt (config_file ())

let default_domain () =
  Option.map String.trim (Fs.read_file_opt (default_domain_file ())) |> function
  | Some "" -> None
  | x -> x
