(** The collection generation G (spec 02 §2.12): even while no collection has
    deletions on copies in flight, odd while one has. *)

(** Absent reads as [Some 0]; a body that does not parse, or a value that is not
    a non-negative integer, as [None], which callers treat as odd. *)
val read : Store.t -> Tsync_core.Domain_name.t -> int option

val encode : int -> Tsync_core.Bigstring.t
