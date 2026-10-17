(** [tsync totp <verb>] (spec extensions/totp §5) over every domain that uses
    the extension, merged as extensions README §6.1 says. *)

val cmds : int Cmdliner.Cmd.t list
