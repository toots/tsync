(** [config share] and [config join] (spec algorithms/setup-link.md §5, §6). *)

val share_cmd : int Cmdliner.Cmd.t
val join_cmd : int Cmdliner.Cmd.t

(** Joins [link], as [config join] does; [bool] is verbosity. *)
val join : string -> bool -> int
