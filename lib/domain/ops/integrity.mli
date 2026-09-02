(** Asking every store to check what it holds, and watching the answers arrive.

    The stores are what this walks, not the local manifests: a chunk is
    checkable wherever it sits, and what a client happens to have cached says
    nothing about the copy a store is keeping.

    A store checks itself through its own machinery — a request written under
    {!Chunk_layout.verify_jobs_prefix} that the bucket's notification carries to
    a function — so what comes back is progress, not a verdict. The verdict is
    read afterwards by listing {!Chunk_layout.corrupted_prefix}, which is
    {!Corruption}'s.

    An {!answer}'s [queued] is [None] for a store with nothing on its side to
    run a check, which is reported rather than passed over: a store that never
    looked and a store that looked and found nothing both list zero markers. *)
type answer = { store : string; queued : int option }

(** Whether a report is anything other than a clean bill of health. A silent
    store counts: zero markers out of a store nothing checked is not the same
    answer as zero markers out of one that did. *)
val unhealthy : Corruption.report -> bool

(** Repairing what a store filed: Put right the chunks a store filed as corrupt
    ({!Corruption}), by finding a copy that hashes to the key and writing it
    back over the bad one.

    It never removes a marker: the store clears one by re-verifying the object
    it was handed, so a repair made and a repair merely intended cannot be told
    apart by anything written here.

    It needs another store holding the chunk — a chunk corrupt on every backend
    is reported lost rather than recovered from this machine's cache, which is
    filed by group key and disposable by design. *)
type repair =
  | Repaired of { from_store : string }
  | Cleared
      (** The store's own copy is already correct, the marker having outlived
          the write that fixed it; rewriting the body is what makes the store
          look again. *)
  | Unrepairable  (** No store holds bytes that hash to this key. *)

type repair_stats = {
  checked : int;
  repaired : int;
  cleared : int;
  unrepairable : int;
  lost : string list;  (** the keys nothing could supply *)
}

(** One line for a report, e.g. ["FIXED <key> on cloud (from disk)"]. *)
val describe_repair : chunk_key:string -> store:string -> repair -> string

module Over
    (Io : Io.S)
    (_ : Clock.S with type 'a io := 'a Io.t)
    (_ : Corruption.OVER with type 'a io := 'a Io.t) : sig
  module Make (C : Conf.S with type 'a io = 'a Io.t) : sig
    (** Ask every member to check itself, then watch the ones that accepted
        until their requests drain.

        [on_answers] is called once, with every member's reply, before any
        watching begins. [`Nothing_queued] when no store accepted — a caller
        should treat that as a failure rather than report a check that never
        happened.

        The watchers run together, so [on_progress] and its companions are
        called for several stores interleaved and each carries the store it
        speaks for. *)
    val verify :
      on_answers:(answer list -> unit) ->
      on_progress:(store:string -> left:int -> found:int -> unit) ->
      on_done:(store:string -> found:int -> unit) ->
      on_stalled:(store:string -> unit) ->
      unit ->
      [ `Watched | `Nothing_queued ] Io.t

    (** Watch one store's requests drain. [on_progress] fires once per poll,
        [on_done] when nothing is left, and [on_stalled] when the count has not
        moved for several polls — which is what an undeployed or misfiltered
        bucket notification looks like from here, and is said out loud rather
        than waited on. *)
    val follow :
      on_progress:(store:string -> left:int -> found:int -> unit) ->
      on_done:(store:string -> found:int -> unit) ->
      on_stalled:(store:string -> unit) ->
      (module C.Store) Backend.member ->
      unit Io.t

    (** Repair every marked chunk. [source] narrows the candidate copies to one
        named store; by default every readable member is tried in configuration
        order, which puts the main first.

        A candidate is hashed before it is trusted: a copy can be wrong too, and
        writing one bad body over another would spread the damage while
        reporting a repair. [dry_run] does everything but the write.

        The bad copy is written directly rather than through {!Conf.S.store}:
        only one store is wrong, and a fan-out write would re-send the chunk to
        healthy ones and queue deferred jobs for them.

        [on_start] fires once the marked chunks are known and [on_chunk] carries
        the position within that total, a repair being a chunk-sized read and
        write apiece and so long enough that a caller cannot otherwise tell work
        in progress from a stall.

        Raises [Failure] on a read-only domain. *)
    val repair :
      ?source:string ->
      ?dry_run:bool ->
      ?on_start:(total:int -> unit) ->
      ?on_chunk:
        (done_:int ->
        total:int ->
        chunk_key:string ->
        store:string ->
        repair ->
        unit) ->
      unit ->
      repair_stats Io.t
  end
end
