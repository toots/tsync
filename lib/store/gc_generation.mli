(** The collection generation G (spec 02 §2.12): even while no collection has
    deletions on copies in flight, odd while one has. *)

(** Absent reads as [Some 0]; a body that does not parse, or a value that is not
    a non-negative integer, as [None], which callers treat as odd. *)
val read : Store.t -> Tsync_core.Domain_name.t -> int option

(** G as a client sees it: the maximum over its mains, since only the collecting
    one holds it, and [None] when any main cannot answer. *)
val read_mains : Store.t list -> Tsync_core.Domain_name.t -> int option

val encode : int -> Tsync_core.Bigstring.t

(** A plain put: only a holder of the run lock writes G. *)
val write : Store.t -> Tsync_core.Domain_name.t -> int -> unit

(** With the run lock held: an odd G whose deletions [owed] counts none of
    becomes the next even value (gc.md §5.7). *)
val settle : Store.t -> Tsync_core.Domain_name.t -> owed:(int -> int) -> unit
