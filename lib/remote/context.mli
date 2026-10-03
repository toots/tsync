(** What the remote model needs of a domain (a slice of the Domain Context of
    spec 05 §3). The remote layer is a functor over it, so the store and the
    domain's policies are in scope of every operation. *)

open Tsync_core
open Tsync_store

module type S = sig
  val domain : Domain_name.t

  (** The composite: every domain key goes through it. *)
  val store : Store.t

  val composite : Composite.t
  val versioning : bool

  (** The configured chunk size, if any. *)
  val chunk_size_config : int option

  val max_downloads : int

  (** Chunk bodies held in memory across all uploads. *)
  val max_chunk_buffers : int
end
