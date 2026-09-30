(** A validated domain name (spec 01 §2.2). *)

type t = private string

(** [local_store] also refuses reserved names in any ASCII case. *)
val of_string : ?local_store:bool -> string -> (t, string) result

(** Raises INVALID. *)
val v : ?local_store:bool -> string -> t

val to_string : t -> string
val equal : t -> t -> bool
val compare : t -> t -> int
