(* Applied once: a session's memo of chunks known present is per store, and the
   store is what {!Chunk_store.Over.Make} is given. *)
include Chunk_store.Over (Io_lwt.Core) (Io_lwt.Bounded)
