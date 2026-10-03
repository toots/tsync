(** The store-class commands (07 §2.5): [gc], [expire], [trash --purge], each a
    dry run unless [--apply]. *)

val cmds : int Cmdliner.Cmd.t list
