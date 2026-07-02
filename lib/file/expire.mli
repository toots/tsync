(** Prune version history and garbage-collect unused chunks.

    [cutoff] governs versions only: every version whose timestamp predates it is
    deleted. Chunk removal is then a pure reference sweep — a chunk not
    referenced by any live file or any surviving version is deleted regardless
    of its age or the cutoff.

    Mark-and-sweep races with a concurrent upload (which writes chunks before
    its manifest), so this is an admin command meant to run while clients are
    idle. *)

type stats = { versions_deleted : int; chunks_deleted : int; chunks_kept : int }

module Make (C : Conf.S) : sig
  (** [expire ~cutoff ()] deletes versions older than [cutoff] (seconds since
      the epoch), then deletes every chunk no longer referenced. Reads from the
      primary backend; deletions fan out to all backends. *)
  val expire : cutoff:float -> unit -> stats
end
