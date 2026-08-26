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

module Make (C : Conf_lwt.S) : sig
  (** Ask every member to check itself, then watch the ones that accepted until
      their requests drain.

      [on_answers] is called once, with every member's reply, before any
      watching begins. [`Nothing_queued] when no store accepted — a caller
      should treat that as a failure rather than report a check that never
      happened.

      The watchers run together, so [on_progress] and its companions are called
      for several stores interleaved and each carries the store it speaks for.
  *)
  val verify :
    on_answers:(answer list -> unit) ->
    on_progress:(store:string -> left:int -> found:int -> unit) ->
    on_done:(store:string -> found:int -> unit) ->
    on_stalled:(store:string -> unit) ->
    unit ->
    [ `Watched | `Nothing_queued ] Lwt.t

  (** Watch one store's requests drain. [on_progress] fires once per poll,
      [on_done] when nothing is left, and [on_stalled] when the count has not
      moved for several polls — which is what an undeployed or misfiltered
      bucket notification looks like from here, and is said out loud rather than
      waited on. *)
  val follow :
    on_progress:(store:string -> left:int -> found:int -> unit) ->
    on_done:(store:string -> found:int -> unit) ->
    on_stalled:(store:string -> unit) ->
    (module Backend_lwt.Store) Backend.member ->
    unit Lwt.t
end
