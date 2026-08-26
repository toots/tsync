(** Put right the chunks a store filed as corrupt ({!Corruption}), by finding a
    copy that hashes to the key and writing it back over the bad one.

    It never removes a marker: the store clears one by re-verifying the object
    it was handed, so a repair made and a repair merely intended cannot be told
    apart by anything written here.

    It needs another store holding the chunk — a chunk corrupt on every backend
    is reported lost rather than recovered from this machine's cache, which is
    filed by group key and disposable by design. *)

type outcome =
  | Repaired of { from_store : string }
  | Cleared
      (** The store's own copy is already correct, the marker having outlived
          the write that fixed it; rewriting the body is what makes the store
          look again. *)
  | Unrepairable  (** No store holds bytes that hash to this key. *)

type stats = {
  checked : int;
  repaired : int;
  cleared : int;
  unrepairable : int;
  lost : string list;  (** the keys nothing could supply *)
}

(** One line for a report, e.g. ["FIXED <key> on cloud (from disk)"]. *)
val describe : chunk_key:string -> store:string -> outcome -> string

module Make (C : Conf_lwt.S) : sig
  (** Repair every marked chunk. [source] narrows the candidate copies to one
      named store; by default every readable member is tried in configuration
      order, which puts the main first.

      A candidate is hashed before it is trusted: a copy can be wrong too, and
      writing one bad body over another would spread the damage while reporting
      a repair. [dry_run] does everything but the write.

      The bad copy is written directly rather than through {!Conf_lwt.S.store}:
      only one store is wrong, and a fan-out write would re-send the chunk to
      healthy ones and queue deferred jobs for them.

      [on_start] fires once the marked chunks are known and [on_chunk] carries
      the position within that total, a repair being a chunk-sized read and
      write apiece and so long enough that a caller cannot otherwise tell work
      in progress from a stall.

      Raises [Failure] on a read-only domain. *)
  val run :
    ?source:string ->
    ?dry_run:bool ->
    ?on_start:(total:int -> unit) ->
    ?on_chunk:
      (done_:int ->
      total:int ->
      chunk_key:string ->
      store:string ->
      outcome ->
      unit) ->
    unit ->
    stats Lwt.t
end
