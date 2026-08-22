(** A file's content as a sequence of named slices.

    A chunk is a fixed-size slice of a file's bytes named by the hash of those
    bytes, so a name is a fact about content rather than about where it is kept:
    two clients cutting the same file the same way agree without speaking, which
    is what makes dedup, mirroring and repair work at all.

    Pure — no store, no config, no event loop. Where a chunk is kept is
    {!Chunk_keyspace}'s. *)

(** The key a body belongs under. The one place this is composed: an uploader
    publishes it and a check recomputes it, and the two must not drift. *)
val key_of_body : Bigstring.t -> string

(** Whether a name is shaped like a key. Asked while walking a store, where the
    answer decides whether something is copied or deleted, so it says what the
    name {i is} rather than what it is not — see {!Xxhash.is_hex}. *)
val is_chunk_key : string -> bool

(** {1 How a file maps onto its chunks}

    Every chunk is [chunk_size] bytes but the last, so all four of these are
    functions of the file's size and that one setting — recorded per file in its
    own body, never global. Naming them here is what keeps a reader and a writer
    cutting at the same boundaries. *)

(** Chunks in a file of [size]. Zero for an empty file. *)
val count : size:int64 -> chunk_size:int -> int

(** The chunk holding byte [pos]. *)
val index_of : chunk_size:int -> int -> int

(** The first byte chunk [i] holds. *)
val offset_of : chunk_size:int -> int -> int

(** Bytes chunk [i] holds: [chunk_size] for every chunk but the last, and 0 for
    an index past the end. *)
val length_of : size:int64 -> chunk_size:int -> int -> int
