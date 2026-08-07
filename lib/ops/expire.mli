(** Prune version history and the journal, and garbage-collect unused chunks.

    [cutoff] governs versions and journal entries: each is deleted when its
    timestamp predates it. Chunk removal is then a pure reference sweep — a
    chunk not referenced by any live file or any surviving version is deleted
    regardless of its age or the cutoff.

    Trimming the journal by age means a client that has been offline for longer
    than the retention window can no longer catch up incrementally and must
    resync — which is already true of the versions and trashed files it missed.

    Mark-and-sweep races with a concurrent upload (which writes chunks before
    its manifest), so this is an admin command meant to run while clients are
    idle. *)

type stats = {
  versions_deleted : int;
  chunks_deleted : int;
  chunks_kept : int;
  journal_deleted : int;
}

module Make (C : Conf.S) : sig
  (** [expire ~cutoff ()] deletes versions and journal entries older than
      [cutoff] (seconds since the epoch), then deletes every chunk no longer
      referenced. Reads from the primary backend; deletions fan out to all
      backends. *)
  val expire : cutoff:float -> unit -> stats Lwt.t
end
