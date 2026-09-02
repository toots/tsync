(** Splitting a list into fixed-size runs.

    Written out per op, and three of the four spellings walk the list twice with
    {!List.filteri} after asking for its length — quadratic over a loop that
    takes the head off repeatedly, which is exactly how it is used. *)

(** Keys per bulk delete: what s3 and gcs both accept per request, so a delete
    batched here costs a driver nothing and reports progress from inside a long
    run. *)
val per_delete : int

(** The first [n] elements and the rest, in one pass. *)
val take : int -> 'a list -> 'a list * 'a list
