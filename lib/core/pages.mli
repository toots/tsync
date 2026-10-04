(** Cutting a list into pages: the one spelling of "the next [n]". *)

(** The first [n] items, and the rest. *)
val take : int -> 'a list -> 'a list * 'a list

(** Pages of at most [n] items, in order; none for the empty list. *)
val cut : int -> 'a list -> 'a list list
