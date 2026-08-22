(** Bringing this client's view of a domain back in line with the store.

    Two ways, and the choice between them is the point: apply the journal
    entries published since the local bookmark, or — when there is no bookmark,
    when the journal cannot carry one to now, or when the caller insists —
    clear the cache and rebuild the manifest mirror by walking the folder tree
    whole.

    One pass of the same engine the daemon polls with, so the two cannot drift
    apart. *)

type outcome =
  | Full of { manifests : int; failed : int; reason : string }
      (** [reason] is why a full rebuild was chosen, for a caller that reports
          it. [failed] counts children that could not be read or classified;
          a rebuild that did not reach everything leaves the bookmark alone. *)
  | Incremental of { applied : int }

(** Where a long run has got to, for a caller reporting on it. There is no
    total: the folder tree is discovered as it is walked, so a denominator would
    be one this cannot know. *)
type progress = {
  on_phase : string -> unit;
  on_current : string option -> unit;
      (** The folder being walked, [None] once the walk is done. *)
}

module Make (C : Conf.S) : sig
  (** [notify] is called once the rebuild is complete and never before, or a
      daemon told earlier re-reads a mirror that is still being written.
      [on_decision] receives the local mark, the published journal and why a
      rebuild was chosen (or [None] for an incremental pass), once that is
      settled and before anything acts on it.

      [full] forces a rebuild that the bookmark would not have required.
      [parallelism] bounds the concurrent backend reads of the walk. *)
  val run :
    ?full:bool ->
    ?progress:progress ->
    ?on_manifest:(string -> unit) ->
    ?on_decision:
      (Journal.Entry_key.t option ->
      Journal.Entry_key.t list ->
      string option ->
      unit) ->
    parallelism:int ->
    notify:(unit -> unit) ->
    unit ->
    outcome Lwt.t

  (** How far this client has applied the shared journal, for a caller that
      reports it without running a pass. *)
  val bookmark : unit -> Journal.Entry_key.t option

  val client_uuid : unit -> string
end
