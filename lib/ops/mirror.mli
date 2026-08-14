(** Remote resync: bring one backend up to date from another, copying every
    object of the domain (manifests, chunks, journal, versions, cursor) that is
    missing or size-mismatched on the destination. *)

type dest_stats = {
  name : string;  (** the destination member's configured name *)
  checked : int;  (** source objects examined *)
  copied : string list;  (** keys copied, sorted *)
  copied_bytes : int;
}

module Make (C : Conf.S) : sig
  (** Copy from the {!Conf.members} entry named [source] (default the first,
      which role order makes a main) to every other one. Copies between the
      stores themselves rather than through {!Conf.store}: the point is to reach
      the ones the composite writes off the caller's path, or does not write at
      all. Additive only: objects deleted on the source are not deleted on the
      destinations. Returns one [dest_stats] per destination, in configuration
      order.

      Raises [Failure] when nothing has the name [source].

      [scope] selects what is copied:
      - [`All], every namespace plus the cursor;
      - [`Manifests], the manifests namespace alone ([C.domain_prefix], skipping
        chunks/journal/versions/cursor) — cheap way to complete a backend's
        structure without hauling chunk data;
      - [`Path rel], the files under the domain-relative folder [rel] and the
        chunks their manifests name, skipping journal/versions/cursor, which
        describe the domain rather than a subtree. Raises [Failure] when the
        source is missing an object the scope selected: this command copies a
        full backend onto a partial one, so that is the source being wrong.

      [verify] hashes each destination chunk against the key it is filed under
      instead of trusting its size, so a body that is the right length and the
      wrong bytes is recopied. Reads every candidate chunk off the destination;
      pair it with [`Path] unless re-reading the whole chunk store is intended.

      [on_list] fires before each step of working out what the source holds,
      [name] being that step phrased for a progress line. [on_scan] fires once
      with the total number of source objects to examine, after listing and
      before copying. [on_copy] fires per object actually copied, with the
      destination's name, the bytes written, and what was wrong with the
      destination's copy: [`Missing], [`Wrong_size], or — only reachable under
      [verify] — [`Wrong_body], a body of the right length that does not hash to
      the key holding it. *)
  val resync :
    ?source:string ->
    ?verify:bool ->
    ?scope:[ `All | `Manifests | `Path of string ] ->
    ?on_scan:(objects:int -> unit) ->
    ?on_list:(name:string -> unit) ->
    ?on_copy:
      (name:string ->
      key:string ->
      reason:[ `Missing | `Wrong_size | `Wrong_body ] ->
      bytes:int ->
      unit) ->
    unit ->
    dest_stats list Lwt.t
end
