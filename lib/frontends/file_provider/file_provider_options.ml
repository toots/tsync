let fields : Tsync_core.Field_spec.field list = []

let () =
  Tsync_config.Frontend.register "file_provider" { fields; presenting = true }
