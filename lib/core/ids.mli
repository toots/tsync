(** Random identifiers (spec 01 §2.10). *)

(** Bytes from the operating system's secure generator; raises if it cannot be
    read, with no fallback. *)
val urandom : int -> string

val hex : string -> string

(** 16 secure random bytes as 32 lowercase hex: share tokens, the client uuid.
*)
val token : unit -> string

(** 32 secure random bytes as 64 lowercase hex: http-proxy secrets. *)
val secret : unit -> string

(** 16 lowercase hex from a seeded generator, reseeded in a forked child:
    staged-body names and trash entries. *)
val short : unit -> string
