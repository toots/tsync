(** A set of chunk keys held as 16 packed bytes each, by shard: what a memo of
    millions of chunks costs is their digests, not a heap string and a table
    entry apiece. Not synchronised: its owner's lock covers it. *)

type t

(** Past [max] keys (default 8 million, about 200 MB) the set empties itself and
    calls [on_overflow], so what a memo derives from it is reset with it. *)
val create : ?max:int -> ?on_overflow:(unit -> unit) -> unit -> t

val mem : t -> Chunk_key.t -> bool
val add : t -> Chunk_key.t -> unit
val remove : t -> Chunk_key.t -> unit

(** Removes every key of a shard, named by its three hex digits. *)
val clear_shard : t -> string -> unit

val clear : t -> unit
val cardinal : t -> int
