(** A chunk key (spec 01 §3.2): the dual digest of a chunk's bytes. *)

type t = private string

(** Exactly 33 bytes of lowercase dual hex, else [None]. *)
val of_string : string -> t option

(** Raises CORRUPT: a chunk key read from a store that is malformed. *)
val v : string -> t

val of_body : string -> t
val of_bigstring : ?off:int -> ?len:int -> Xxh.bigstring -> t
val to_string : t -> string

(** Its first three characters. *)
val shard : t -> string

(** The key of the empty body, named once by every empty regular file. *)
val empty : t

val equal : t -> t -> bool
val compare : t -> t -> int
