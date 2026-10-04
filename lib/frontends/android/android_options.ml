let fields : Tsync_core.Field_spec.field list = []

let () =
  Tsync_config.Frontend.register "android"
    {
      fields;
      wizard = None;
      presenting = Some `Per_domain;
      commands_only =
        Some
          "the android frontend is driven by the Android app, not by tsync \
           start";
      pulled =
        Some
          "the android frontend keeps a pulled tree, which has no replica to \
           sync";
      group = None;
      commands = Android_cli.commands;
    }
