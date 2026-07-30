(** Chunk store layout, shared by the backend chunk store and the local cache.
*)

(** Number of leading key characters naming a chunk's shard directory. *)
val fanout : int

(** [relative_path key] is ["<shard>/<key>"], the chunk's path relative to the
    store root. The key itself is unchanged: {!Filename.basename} recovers it
    from a listing entry. A key shorter than {!fanout} lands under ["_"]. *)
val relative_path : string -> string
