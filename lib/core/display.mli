(** What a command shows on stderr while it runs (spec 07 §5.1): narration under
    [--verbose], progress unless [--quiet]. On a terminal progress is one line
    redrawn in place with the elapsed time, cleared before every other line;
    elsewhere it is a line every 10 seconds. *)

type mode = Quiet | Normal | Verbose

(** Once, from the command's arguments; [quiet] wins over [verbose]. Takes over
    the log's sink so a log line clears the progress line first. *)
val configure : verbose:bool -> quiet:bool -> unit

(** This process's display as an operation's sink. *)
val narrate : unit -> Narrate.t

(** A line of the command's result on stdout. *)
val out : string -> unit

(** Remove the progress line; also run at exit. *)
val clear : unit -> unit
