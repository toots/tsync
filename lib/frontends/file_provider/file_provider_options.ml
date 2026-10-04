let fields : Tsync_core.Field_spec.field list = []

let () =
  Tsync_config.Frontend.register "file_provider"
    {
      fields;
      wizard =
        Some
          {
            systems = [`Macos];
            question = "show it in Finder on this machine";
            asks = [];
          };
      presenting = Some `Shared;
      commands_only = None;
      pulled = None;
      group = Some "fileprovider";
      commands = File_provider_cli.commands;
    }
