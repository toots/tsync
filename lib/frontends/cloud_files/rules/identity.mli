(** A placeholder's file identity (cloud-files §8.1): what the provider gets
    back from the system for every placeholder it made, whatever its name. *)

(** [content_id] is empty for a folder. *)
type t = { ref_ : string; content_id : string }

(** Three lines, UTF-8: [t1], the reference, the content id. *)
val encode : t -> string

(** [None] for an identity of another form: a foreign placeholder. *)
val decode : string -> t option
