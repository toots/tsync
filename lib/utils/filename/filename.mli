(** {!Stdlib.Filename}, and the one naming convention this program adds to it.

    A file or object being replaced is written under a staging name and renamed
    over the real one, so a reader never sees a half-written body. The name
    carries the pid that made it, which is what tells a live run's scratch from
    a dead one's leftovers.

    Generating the name and recognising it live together: a collector parses
    every name it lists, and two spellings of this convention would be two
    things that can disagree. *)
include module type of Stdlib.Filename

(** A staging name beside [path], for the same directory. *)
val temp_path : string -> string

(** Whether a name is one {!temp_path} produced. *)
val is_temp_name : string -> bool

(** The pid that made a staging name, or [None] for a name we did not generate.
    What separates a live run's scratch file from a dead run's. *)
val temp_owner : string -> int option
