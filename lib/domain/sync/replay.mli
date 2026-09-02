(** Everything that reads a journal: our own unfinished work, and other
    clients'.

    It lives here rather than in the CLI because both callers need it, and
    because a copy living in an executable was unreachable from [tests/] — which
    is how one domain sat on 295 stale records for hours. *)

module type JOURNAL = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    include File_store.S with type 'a io := 'a io

    (** Keep an entry this client has handled, so what changed since an anchor
        is answered without fetching back from the store what was just read.
        Called after the entry is applied, which is what lets a reader trust
        that the mirror already agrees with it. *)
    val note_applied : Journal.Entry_key.t -> Journal.op list -> unit io

    (** Every entry this client has handled, as far back as it keeps them. *)
    val applied_keys : unit -> Journal.Entry_key.t list io
  end
end

module type S = sig
  type 'a io

  (** Finish or discard every record this client left behind, oldest first, each
      under the entry key it already has. Startup only: it replays ops and
      re-queues uploads, so it must not run while writes are staging.

      Also adopts staged data no record names — a crash between staging and
      recording. Collecting staged bodies nothing references is
      {!File_ops.S.reclaim_staged_orphans}, which may run once per machine
      rather than once per process and so has a caller of its own. *)
  val reconcile : unit -> unit io

  (** Apply every journal entry from another client not yet handled, in key
      order, advancing the mark behind each one. A failure stops the pass and
      leaves the mark where it was, so the entry is retried rather than skipped.

      Not "since the mark": a key says when its writer minted the entry, not
      when the store showed it, so an entry can appear behind the mark. The
      listing reaches back as far as the handled entries are remembered, and
      each is checked against them.

      [on_changed] is called with each affected backend key, for a frontend that
      invalidates its own view. Returns how many foreign entries were applied.
  *)
  val apply_foreign : on_changed:(string -> unit) -> unit -> int io

  (** Remember these entries as handled without applying them: a rebuild has
      read the store they describe, so their effect is already in the mirror. *)
  val mark_handled : Journal.Entry_key.t list -> unit io
end

(** The shape a consumer takes: {!S} for whichever domain it is applied to. *)
module type OVER = sig
  type 'a io

  module Make
      (C : Conf.S with type 'a io = 'a io)
      (F : File_ops.S with type 'a io := 'a io) : S with type 'a io := 'a io
end

module Over
    (Io : Io.S)
    (_ : Bounded.S with type 'a io := 'a Io.t)
    (_ : JOURNAL with type 'a io := 'a Io.t)
    (_ : Wal.OVER with type 'a io := 'a Io.t)
    (_ : Staged_manifest.OVER with type 'a io := 'a Io.t) : sig
  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (F : File_ops.S with type 'a io := 'a Io.t) : S with type 'a io := 'a Io.t
end
