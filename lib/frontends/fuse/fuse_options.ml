open Tsync_core

let subtype_chars s =
  if
    String.for_all
      (fun c ->
        (c >= 'a' && c <= 'z')
        || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9')
        || c = '.' || c = '_' || c = '-')
      s
  then None
  else Some "only letters, digits, '.', '_' and '-'"

let fields =
  Field_spec.
    [
      f ~check:absolute_path "mountPoint" "Mount point" Path;
      f ~default:"false" "allowOther" "Allow other users (read-only)" Bool;
      f ~default:"sshfs" ~check:subtype_chars "mountSubtype" "Mount subtype"
        String;
    ]

let () =
  Tsync_config.Frontend.register "fuse"
    {
      fields;
      presenting = Some `Per_domain;
      commands_only = None;
      group = None;
      commands = [];
    }
