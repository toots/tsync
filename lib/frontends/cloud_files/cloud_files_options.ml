open Tsync_core
open Tsync_config

let fields =
  Field_spec.[f ~check:absolute_path "syncRoot" "Folder shown in Explorer" Path]

let sync_root (d : Config.domain) =
  let options =
    Option.fold ~none:[]
      ~some:(fun (f : Config.frontend) -> f.options)
      (Config.frontend d "cloud_files")
  in
  match Config.fstr options "syncRoot" with
    | Some p when String.trim p <> "" -> p
    | _ -> Paths.mount_point d.name

let () =
  Frontend.register "cloud_files"
    {
      fields;
      wizard =
        Some
          {
            systems = [`Windows];
            question = "show it in Explorer on this machine";
            asks = [];
          };
      presenting = Some `Per_domain;
      commands_only = None;
      pulled = None;
      group = Some "cloudfiles";
      commands = Cloud_files_cli.commands;
    }
