(** The config as a person reads it, one block per domain: its folder, where it
    is stored and what it brings beside the files. No secret appears, as none of
    the fields shown holds one. The Windows installer shows it on its last page
    through [tsync config --summary]. *)
val render : Config.t -> string
