let fields : Tsync_core.Field_spec.field list = []

let () =
  Tsync_config.Frontend.register "android"
    {
      fields;
      presenting = Some `Per_domain;
      commands_only =
        Some
          "the android frontend is driven by the Android app, not by tsync \
           start";
    }
