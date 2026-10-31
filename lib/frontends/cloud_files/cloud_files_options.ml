open Tsync_core
open Tsync_config

let fields =
  Field_spec.[f ~check:absolute_path "syncRoot" "Folder shown in Explorer" Path]

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
