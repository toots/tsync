(** The kept walk of a whole-domain listing (spec 08 §2.5, §3.7): one file per
    domain, a header line naming the walk, then one entry per line sorted by
    path. Pages resume at a byte offset, so a page seeks instead of scanning. *)

type entry = {
  path : string;
  container : string;  (** the parent folder's id *)
  kind : [ `Dir | `File ];
  size : int;
  mtime : int;  (** nanoseconds since the epoch *)
}

(** Replaces the kept walk with the entries [produce] emits, in their order, and
    answers its stamp, never the stamp of the walk it replaces. [produce]
    answers how many items it skipped. Entries go to disk as they are emitted.
*)
val write : string -> ((entry -> unit) -> int) -> string

(** The cursor of the walk's first entry. *)
val first_cursor : string -> string option

(** [limit] entries' paths from [cursor] ([<walk>:<offset>]) and the next cursor
    when one more entry exists; [`Stale] for another walk, a missing file, or an
    offset that does not start an entry line. *)
val page :
  string ->
  cursor:string ->
  limit:int ->
  [ `Stale | `Page of string list * string option ]
