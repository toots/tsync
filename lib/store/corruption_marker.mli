(** The body of a corruption marker (spec 02 §2.13): the finding is the key; the
    body says what was seen. *)

(** [computed] is the digest the bytes hash to, [size] their length, [reason]
    why they could not be read. *)
val body : ?computed:string -> ?reason:string -> int option -> string
