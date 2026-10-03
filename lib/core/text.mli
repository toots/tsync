(** Substring search over plain strings. *)

(** The first position of [sub] in [s] at or after [from]. *)
val find_from : string -> string -> int -> int option

val contains : string -> string -> bool

(** Every occurrence of [sub] replaced by [by], left to right. *)
val replace_all : sub:string -> by:string -> string -> string
