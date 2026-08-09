(** Drop the references that keep old content alive: version history, trashed
    folders, and the journal.

    [cutoff] governs all three — each is deleted when its timestamp predates it.
    What this leaves behind is chunks nothing points at any more, which is
    {!Gc}'s job: expiring is what creates that garbage, collecting it is a
    separate step, and the two are separate commands because only some stores
    can do the second.

    Trimming the journal by age means a client that has been offline for longer
    than the retention window can no longer catch up incrementally and must
    resync — which is already true of the versions and trashed files it missed.

    Works on every backend: nothing here needs more of a store than deleting a
    key. *)

type stats = { versions_deleted : int; journal_deleted : int }

module Make (C : Conf.S) : sig
  (** [expire ~cutoff ()] empties trashed folders, then deletes versions and
      journal entries older than [cutoff] (seconds since the epoch). Reads and
      deletions both go through {!Conf.store}, so they reach every configured
      store.

      A domain with a long history takes a while, so the caller is told where it
      is rather than left with a silent process. [name] is the namespace being
      worked on — "trash", "versions" or "journal". [on_list] fires before
      listing one, [on_scan] once its size is known, and [on_delete] per batch
      of deletions with the running total, listing being the part that cannot
      report progress from inside. *)
  val expire :
    ?on_list:(name:string -> unit) ->
    ?on_scan:(name:string -> objects:int -> unit) ->
    ?on_delete:(name:string -> deleted:int -> unit) ->
    cutoff:float ->
    unit ->
    stats Lwt.t
end
