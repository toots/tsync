(** The shared journal on the backend, and the local mark saying how far it has
    been read. The only module that turns an entry key into a backend key. *)

(** How long a cursor bump may wait to be collected with others. Settable so a
    test observing a flush need not sleep it out. *)
val set_cursor_flush_interval : float -> unit

(** The one lock here: a timer flush and a drain flush landing together would be
    two concurrent writes to the object this exists to write less often. *)
module type LOCKS = sig
  type 'a io
  type mutex

  val mutex : unit -> mutex
  val with_lock : mutex -> (unit -> 'a io) -> 'a io
end

(** How long a cursor bump may wait to be collected with others. *)
module type CLOCK = sig
  type 'a io

  val sleep : float -> unit io
end

(** The manifest-level reads a journal entry needs to name what it is about. *)
module type MANIFESTS = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val copy_manifest :
      src_key:Logical_key.t -> dst_key:Logical_key.t -> unit io

    val head_manifest : key:Logical_key.t -> Backend.file_entry option io
  end
end

module Over
    (Io : Io.S)
    (_ : LOCKS with type 'a io := 'a Io.t)
    (_ : CLOCK with type 'a io := 'a Io.t)
    (_ : MANIFESTS with type 'a io := 'a Io.t) : sig
  (** {!Data.JOURNAL} asks which monad this answers in. *)
  type 'a io = 'a Io.t

  module Make (C : Conf.S with type 'a io = 'a Io.t) : sig
    val rename_file :
      src_key:Logical_key.t -> dst_key:Logical_key.t -> unit Io.t

    (** Heads a *file key*'s manifest object, resolving it through the layout.
        Journal objects are not manifests — see {!journal_entry_published}. *)
    val head_manifest_opt : key:Logical_key.t -> Backend.file_entry option Io.t

    val write_journal_entry :
      ?entry_key:Journal.Entry_key.t ->
      Journal.op list ->
      Journal.Entry_key.t Io.t

    (** {!write_journal_entry} for a body already encoded, and for the caller
        that assembled it somewhere other than the heap: an import records one
        op per file, and their encoding is the largest string it would otherwise
        hold. *)
    val write_journal_entry_body :
      ?entry_key:Journal.Entry_key.t -> Bigstring.t -> Journal.Entry_key.t Io.t

    (** Point peers at [entry_key]. The cursor is one object name and a store
        rate-limits writes to it, so bumps are coalesced: this publishes at once
        when the cursor has been quiet and otherwise records the key and
        returns, leaving a timer to publish the newest of the burst.

        It may therefore return before the write lands. Every path that bumps
        must be reachable by a {!flush_cursor} before the process exits, or the
        last bump of a run is lost and peers never go looking for what it
        published. *)
    val bump_cursor : Journal.Entry_key.t -> unit Io.t

    (** {!bump_cursor} that never publishes inline, for a caller that cannot
        await one — the upload queue's hook is synchronous. *)
    val note_cursor : Journal.Entry_key.t -> unit

    (** Publish what is pending now rather than waiting the interval out. A
        no-op with nothing pending, and it swallows a backend failure: it runs
        from a timer and from drain, neither of which may die of one. *)
    val flush_cursor : unit -> unit Io.t

    val fetch_cursor : unit -> Journal.Entry_key.t option Io.t

    (** Wait for the cursor to be worth reading again — how, and for how long,
        being the store's to decide ({!Backend.S.watch}). A hint, so this
        returning means read and compare, not that anything changed.

        [last_seen] is the entry key the caller last read and finished with; a
        store able to compare answers at once when the cursor already points
        past it. *)
    val wait_cursor_change : Journal.Entry_key.t option -> unit Io.t

    (** How far this client has applied the shared journal. [None] when it has
        never synced. Local state — it says what we caught up to, not what has
        been published. *)
    val read_last_sync_key : unit -> Journal.Entry_key.t option

    val write_last_sync_key : Journal.Entry_key.t -> unit

    (** Chronological. [start_after] is exclusive. Entries whose name no client
        wrote are skipped. *)
    val list_journal_keys :
      ?start_after:Journal.Entry_key.t -> unit -> Journal.Entry_key.t list Io.t

    val get_journal_entry : Journal.Entry_key.t -> Journal.op list option Io.t

    (** Whether the entry's object is on the backend, i.e. this entry was
        published. The entry-key-to-backend-key mapping lives here so a caller
        cannot forget the month directory {!Journal.Entry_key.relative_path}
        adds. *)
    val journal_entry_published : Journal.Entry_key.t -> bool Io.t
  end
end
