(** Splitting a list into fixed-size runs.

    Written out per op, and three of the four spellings walk the list twice with
    {!List.filteri} after asking for its length — quadratic over a loop that
    takes the head off repeatedly, which is exactly how it is used. *)

(** The first [n] elements and the rest, in one pass. *)
val take : int -> 'a list -> 'a list * 'a list
