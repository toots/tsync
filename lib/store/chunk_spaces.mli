(** The two chunk spaces of a collectable filesystem store (spec
    algorithms/gc.md §5.4, §5.8).

    The store's driver routes every chunk access and every write into a manifest
    or version area through here, so no caller learns that a collection exists.
    The collector uses {!promote}, {!with_publish_lock} and {!run_open} and
    nothing else. On a root that is not collectable every operation is the plain
    one. *)

open Tsync_core

type t

(** [collectable] says whether the root is on a filesystem local to this host
    (gc.md A1). *)
val create : collectable:(unit -> bool) -> string -> t

val collectable : t -> bool

(** Whether a run record is present, whatever its body. *)
val run_open : t -> Domain_name.t -> bool

(** Whether a chunk is in the surviving space: a stat, not a belief. *)
val in_surviving : t -> Domain_name.t -> Chunk_key.t -> bool

(** Run [f] holding the publish lock, shared or exclusive, waiting at most
    [wait] seconds (default 30) and then failing DEADLINE. *)
val with_publish_lock :
  ?wait:float -> t -> Domain_name.t -> exclusive:bool -> (unit -> 'a) -> 'a

(** Move a chunk from the outgoing space to the surviving one; whether this call
    moved it. Not durable until {!sync_shards}. *)
val promote : t -> Domain_name.t -> Chunk_key.t -> bool

(** Make earlier promotions of these chunks durable. *)
val sync_shards : t -> Domain_name.t -> Chunk_key.t list -> unit

(** The reference gate around [write], which puts [body ()] at [key] (§5.4):
    promotes the chunks the body names while a run is open, then refuses with
    MISSING_CHUNKS any the surviving space lacks. A body naming no chunk passes
    without the lock; one that is neither a manifest nor a JSON record is
    INVALID. Keys outside a manifest or version area pass. *)
val gate : t -> key:Key.t -> body:(unit -> Bigstring.t) -> (unit -> 'a) -> 'a

(** A read of a surviving-space chunk key through [f]: the surviving space,
    then, while a run is open, the outgoing one. Other keys are read once. *)
val read : t -> Key.t -> (Key.t -> 'a option) -> 'a option

(** The files a delete of [key] removes: a chunk in both spaces. *)
val twins : t -> Key.t -> Key.t list

(** A listing through [raw]: both spaces under surviving-space keys, each chunk
    once, and nothing else of an outgoing space. Unsorted. *)
val list :
  t -> Key.prefix -> (Key.prefix -> Store.entry list) -> Store.entry list
