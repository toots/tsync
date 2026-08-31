(** Everything that reads a journal: our own unfinished work, and other
    clients'.

    It lives here rather than in the CLI because both callers need it, and
    because a copy living in an executable was unreachable from [tests/] — which
    is how one domain sat on 295 stale records for hours. *)

(** What this needs below it. *)
module type JOURNAL = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val write_journal_entry :
      ?entry_key:Journal.Entry_key.t ->
      Journal.op list ->
      Journal.Entry_key.t io

    val bump_cursor : Journal.Entry_key.t -> unit io

    val list_journal_keys :
      ?start_after:Journal.Entry_key.t -> unit -> Journal.Entry_key.t list io

    val get_journal_entry : Journal.Entry_key.t -> Journal.op list option io

    (** Keep an entry this client has handled, so what changed since an anchor
        is answered without fetching back from the store what was just read.
        Called after the entry is applied, which is what lets a reader trust
        that the mirror already agrees with it. *)
    val note_applied : Journal.Entry_key.t -> Journal.op list -> unit io

    val journal_entry_published : Journal.Entry_key.t -> bool io
    val read_last_sync_key : unit -> Journal.Entry_key.t option
    val write_last_sync_key : Journal.Entry_key.t -> unit
  end
end

module type WAL = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val list : unit -> (Journal.Entry_key.t * Wal.record) list io
    val complete : Journal.Entry_key.t -> unit io
    val note_failure : Journal.Entry_key.t -> Retry.kind -> string -> unit io
  end
end

module type STAGED = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val list : unit -> Logical_key.t list io
  end
end

module type POOLS = sig
  type 'a io
  type t

  val create : ?max_waiting:int -> ?name:string -> max:int -> unit -> t
  val iter_with : t -> ('a -> unit io) -> 'a list -> unit io
end

module Over
    (Io : Io.S)
    (_ : POOLS with type 'a io := 'a Io.t)
    (_ : JOURNAL with type 'a io := 'a Io.t)
    (_ : WAL with type 'a io := 'a Io.t)
    (_ : STAGED with type 'a io := 'a Io.t) : sig
  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (F : File_ops.S with type 'a io := 'a Io.t) : sig
    (** Finish or discard every record this client left behind, oldest first,
        each under the entry key it already has. Startup only: it replays ops
        and re-queues uploads, so it must not run while writes are staging.

        Also adopts staged data no record names — a crash between staging and
        recording. Collecting staged bodies nothing references is
        {!File_ops.S.reclaim_staged_orphans}, which may run once per machine
        rather than once per process and so has a caller of its own. *)
    val reconcile : unit -> unit Io.t

    (** Apply every journal entry from another client since the applied mark, in
        order, advancing the mark behind each one. A failure stops the pass and
        leaves the mark where it was, so the entry is retried rather than
        skipped.

        [on_changed] is called with each affected backend key, for a frontend
        that invalidates its own view. Returns how many foreign entries were
        applied. *)
    val apply_foreign : on_changed:(string -> unit) -> unit -> int Io.t
  end
end
