type t

(** Parse a shell-like glob pattern ([*], [?], [**]). *)
val of_pattern : string -> t

val matches : t -> string -> bool
