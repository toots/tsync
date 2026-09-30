(** The [gcs] driver (spec backends/gcs.md). Registers itself when linked. *)

(**/**)

val segment : string -> string
val rfc3339 : string -> float
val delete_body : string list -> string
val delete_errors : string -> (string * string) list
