(** One lock per key, with a generation counting the key's content changes (spec
    04 §3.2). A key nobody holds or waits for, and never bumped, keeps no entry,
    so a walk that locks every path of a domain leaves nothing behind. *)

type t

val create : unit -> t

(** Runs [f] holding the key's lock. *)
val with_key : t -> string -> (unit -> 'a) -> 'a

(** The key's generation: equal across two reads iff no {!bump} came between. *)
val generation : t -> string -> int

val bump : t -> string -> unit

(** Entries kept. *)
val size : t -> int
