open Tsync_core
open Tsync_store

module type S = sig
  val domain : Domain_name.t
  val store : Store.t
  val composite : Composite.t
  val versioning : bool
  val chunk_size_config : int option
  val max_downloads : int
  val max_chunk_buffers : int
end
