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

(** {1 The folder tree}

    What a walk of the store's folder tree found wrong with its shape. A folder
    id is meant to live at one place; a marker a move left behind gives it two,
    and a client naming folders by id then shows it at one of them and not the
    other, with nothing looking wrong. Only a client can find these: they are a
    property of the tree, not of any one object. *)
type tree_finding =
  | Twice of { id : string; paths : string list }
      (** One folder id reachable from more than one path. *)
  | Disowned of { marker : Stored_key.t; anchor : Folder.anchor }
      (** A marker the folder's anchor contradicts: the marker names a place the
          folder no longer lives at. Its own path is not known, the walk having
          skipped it; [anchor] says where the folder is. *)
  | Unanchored of { path : string; id : string; parent : string }
      (** A folder written before anchors were, taken at its marker's word. *)
  | Orphan of { id : string; objects : int; sample : string list }
      (** A namespace no marker reaches from the root or the trash. Never
          removed here: it may hold files a client wrote and nobody can name. *)
  | Trashed_live of { id : string; path : string; entry : Stored_key.t }
      (** A trash entry naming a folder that is reachable from the root: it was
          restored or re-filed and the entry never went. Reclaiming the trash
          would delete the live folder, so {!Retention} passes such an entry
          over once the folder is anchored, and a repair removes it. *)

type tree_report = {
  findings : tree_finding list;
  orphans_checked : bool;
      (** False when no main store is on this machine's disk: an orphan is only
          findable by reading the store's directory. *)
}

val tree_unhealthy : tree_report -> bool
val describe_finding : tree_finding -> string

type tree_repair = {
  removed : int;  (** disowned markers and stale trash entries deleted *)
  anchored : int;  (** anchors written for folders that had none *)
  left : tree_finding list;
      (** what a repair does not touch, and what it could not remove *)
}

module Over
    (Io : Io.S)
    (_ : Clock.S with type 'a io := 'a Io.t)
    (_ : Corruption.OVER with type 'a io := 'a Io.t)
    (_ : Fs.S with type 'a io := 'a Io.t)
    (_ : Inode_tree.OVER with type 'a io := 'a Io.t)
    (_ : Store.INODE with type 'a io := 'a Io.t) : sig
  module Make (C : Conf.S with type 'a io = 'a Io.t) : sig
    (** Walk the tree from the root and say what is wrong with its shape. Reads
        only. *)
    val tree_report : unit -> tree_report Io.t

    (** Delete every disowned marker and anchor every folder that has none. A
        delete that removed nothing is reported in [left] rather than counted.
        Raises [Failure] on a read-only domain. *)
    val repair_tree : ?dry_run:bool -> unit -> tree_repair Io.t

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
