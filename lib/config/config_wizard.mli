(** The config wizard (spec 07 §5.9): edits the raw JSON through prompts, so
    nothing it does not ask about is lost. The terminal is the caller's: a test
    answers from a script. *)

type prompt = {
  label : string;
  default : string option;  (** shown, and kept on a blank answer *)
  secret : bool;  (** read without echo *)
}

type io = { ask : prompt -> string; say : string -> unit }

(** From the current file's JSON, or a new one; [None] when the user quits
    without writing. Fails INVALID for a file whose top level is not an object.
*)
val edit : io -> Yojson.Safe.t option -> Yojson.Safe.t option

(** What is written: per-link settings no backend uses dropped, then the
    parser's own validation; [Error] names what is wrong. *)
val prepare : Yojson.Safe.t -> (Yojson.Safe.t, string) result
