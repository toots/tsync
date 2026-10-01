(** What every command shares: config and domain resolution, the exit-status
    policy of failure-model §7.5, and common arguments. *)

open Tsync_config

(** Ends a command with this status after its message. *)
exception Exit_with of int

val say : ('a, out_channel, unit, unit, unit, unit) format6 -> 'a

(** Prints [tsync: <sentence>] and ends the command with status 1. *)
val fail : ('a, unit, string, 'b) format4 -> 'a

val config_opt : unit -> Config.t option
val config : unit -> Config.t

(** 07 §5.1: [--domain], else the default domain, else the only one. *)
val domain : ?name:string -> Config.t -> Config.domain

(** Runs the body on the runtime and answers its exit status. *)
val run : (unit -> int) -> int

(** The TLS implementation of [--tls], else of the config. *)
val use_tls : Config.t -> string option -> unit

val verbose : bool Cmdliner.Term.t
val set_verbose : bool -> unit

(** 07 §5.1: [<N>d|h|m|s] with N > 0, as seconds. *)
val duration : float Cmdliner.Arg.conv

val domain_arg : string option Cmdliner.Term.t
val cmd : string -> doc:string -> 'a Cmdliner.Term.t -> 'a Cmdliner.Cmd.t

(** Run an owner job (07 §2.5), streaming its lines; the first interrupt
    cancels it at its next unit boundary, the second exits at once. *)
val run_job : ?name:string -> bool -> Tsync_owner.Jobs.t -> int
