let fields : Tsync_core.Field_spec.field list = []

let () =
  Tsync_config.Frontend.register "file_provider"
    {
      fields;
      presenting = Some `Shared;
      commands_only = None;
      group = Some "fileprovider";
      commands = File_provider_cli.commands;
    }
