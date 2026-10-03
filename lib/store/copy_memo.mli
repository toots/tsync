(** What one copy is believed to hold (spec algorithms/gc.md §5.6, §5.8).

    Every entry is tagged with the collection generation G it was confirmed
    under. The memo reads G itself; a caller asks through a {!view} and never
    learns whether a collection is in flight. *)

open Tsync_core

type t

(** [generation] reads G; [None] (unreadable, unreachable) counts as odd. *)
val create : generation:(unit -> int option) -> unit -> t

(** A reading of G. Take it after reading the source body that makes an entry
    relevant, and use it for the decisions about that body only. *)
type view

val look : t -> view

(** Whether entries may be recorded and relied on under this view. *)
val trusted : view -> bool

(** Believed held: [false] whenever the view forbids relying on the memo. *)
val holds : view -> Chunk_key.t -> bool

(** Record a confirmed presence; nothing while the view is untrusted. *)
val note : view -> Chunk_key.t -> unit

(** Record every chunk [list ()] names in a shard, once per generation; never
    called while untrusted. *)
val learn_shard : view -> string -> (unit -> Chunk_key.t list) -> unit

(** Drop entries for chunks deleted from, or found absent on, the copy. *)
val forget : t -> Chunk_key.t list -> unit
