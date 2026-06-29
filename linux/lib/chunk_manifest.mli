(** MIME type used to tag S3 objects that contain a chunk manifest. *)
val content_type : string

(** Target chunk size in bytes (8 MiB). *)
val chunk_size : int

(** A single chunk: [index] is its zero-based position, [h1]/[h2] are the two
    xxHash3-64 digests (seed 0 and 1) encoded as 16-char hex strings, and [size]
    is the byte count of that chunk. *)
type chunk_entry = { index : int; h1 : string; h2 : string; size : int }

(** A chunk manifest describing how a large file is split into chunks. [v] is
    the format version, [size] is the total file size. *)
type t = { v : int; size : int64; chunk_size : int; chunks : chunk_entry list }

(** [chunk_key e] returns the S3 key suffix for a chunk: ["<h1>-<h2>"]. *)
val chunk_key : chunk_entry -> string

(** Parse a JSON manifest string. Raises on malformed input. *)
val of_string : string -> t

(** Serialise a manifest to a compact JSON string. *)
val to_string : t -> string
