(** Put right the chunks a store filed as corrupt.

    A chunk's key is the hash of its bytes, so a store that took a bad write
    could tell and said so ({!Corruption}). This finds a copy that hashes to the
    key and writes it back over the bad one.

    {b What it will not do.} It never deletes a marker. A marker is cleared by
    the store re-verifying the object it was handed — the [local] driver as it
    takes the write, an s3 or gcs bucket in the function its object-created
    event triggers — so a repair this made and a repair it only believes it made
    cannot be told apart by anything it writes. Removing the marker itself would
    report health on the strength of an intention.

    {b What it needs.} Another store holding the chunk. Nothing reads this
    machine's cache for it: a cached body is filed under a group key covering
    several stored chunks, so finding one there means walking manifests, and a
    cache is disposable in a way a backend is not. A chunk corrupt on every
    backend is reported lost, not recovered. *)

type outcome =
  | Repaired of { from_store : string }
  | Cleared
      (** The store's own copy was already correct, so the marker had outlived
          the write that fixed it — which two object events arriving out of
          order will do. Rewriting the body is what makes the store look again.
      *)
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

module Make (C : Conf.S) : sig
  (** Repair every marked chunk. [source] narrows the candidate copies to one
      named store; by default every readable member is tried in configuration
      order, which puts the main first.

      A candidate is hashed before it is trusted: a copy can be wrong too, and
      writing one bad body over another would spread the damage while reporting
      a repair. [dry_run] does everything but the write.

      The bad copy is written directly rather than through {!Conf.S.store}: only
      one store is wrong, and a fan-out write would re-send the chunk to healthy
      ones and queue deferred jobs for them.

      [on_start] fires once the marked chunks are known and before the first is
      read, and [on_chunk] carries the position within that total. A repair is a
      chunk-sized read and write apiece against a remote store, so a run over a
      store that took real damage is long and almost entirely waiting: without a
      count, a caller has no way to tell work in progress from a stall, which is
      the same thing it could not tell about the sweep that found the damage.

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
