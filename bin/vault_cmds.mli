(** [tsync vault <verb>] (spec extensions/vault §8): owner-class, answered only
    by a serving owner. *)

val cmds : int Cmdliner.Cmd.t list

(** From the terminal without echo, else one line of standard input. *)
val read_passphrase : ?prompt:string -> stdin:bool -> unit -> string

(** A request to the domain's serving owner; UNREACHABLE when none serves. *)
val ask : Tsync_config.Config.domain -> 'a Tsync_owner.Protocol.request -> 'a
