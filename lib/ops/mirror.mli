(** Remote resync: bring one backend up to date from another, copying every
    object of the domain (manifests, chunks, journal, versions, cursor) that is
    missing or size-mismatched on the destination. *)

type dest_stats = {
  name : string;  (** the destination member's configured name *)
  checked : int;  (** source objects examined *)
  copied : int;
  copied_bytes : int;
}

type phase = [ `Listing | `Comparing | `Copying ]

(** [total] is [None] where nothing yet knows it: a listing has no count until
    the store stops answering, and copying has none until the compare that feeds
    it is done. [store] names whatever the phase is working through — a listing
    and its store, a namespace, the key being copied. *)
type progress = {
  phase : phase;
  store : string;
  done_ : int;
  total : int option;
}

val string_of_phase : phase -> string

module Make (C : Conf.S) : sig
  (** Copy from the {!Conf.members} entry named [source] (default the first,
      which role order makes a main) to every other one. Copies between the
      stores themselves rather than through {!Conf.store}: the point is to reach
      the ones the composite writes off the caller's path, or does not write at
      all. Additive only: objects deleted on the source are not deleted on the
      destinations. Returns one [dest_stats] per destination, in configuration
      order.

      Raises [Failure] when nothing has the name [source].

      Destinations are compared by listing them and walking the two listings in
      step, so the cost is one listing per store per namespace rather than a
      HEAD per object per destination, and an object missing on several
      destinations is fetched from the source once. Listings are spooled to disk
      under [C.cache_root] and mapped rather than held, so a namespace of
      millions of keys costs its pages rather than itself. A listing that fails
      fails the run before anything is copied.

      [scope] selects what is copied:
      - [`All], every namespace plus the cursor;
      - [`Manifests], the manifests namespace alone ([C.domain_prefix], skipping
        chunks/journal/versions/cursor) — cheap way to complete a backend's
        structure without hauling chunk data;
      - [`Path rel], the files under the domain-relative folder [rel] and the
        chunks their manifests name, skipping journal/versions/cursor, which
        describe the domain rather than a subtree. A folder is not a namespace,
        so this one probes by key on both sides rather than listing: checking
        the handful of chunks a folder names against a destination's whole chunk
        store is the opposite trade. Raises [Failure] when the source is missing
        an object the scope selected: this command copies a full backend onto a
        partial one, so that is the source being wrong.

      [on_list] fires before each step of working out what the source holds,
      [name] being that step phrased for a progress line. [on_scan] fires once
      with the total number of source objects to examine, after listing and
      before copying. [on_progress] fires throughout, throttled to about one
      call a second and carrying running totals rather than per-item deltas:
      every phase here can run for minutes on a real domain, and a listing in
      particular answers nothing until it is done. [on_copy] fires per object
      actually copied, with the destination's name, the bytes written, and what
      was wrong with the destination's copy: [`Missing] or [`Wrong_size]. Keys
      are reported through it as each copy happens rather than accumulated,
      copies completing out of key order and a first fill of an empty backend
      being every key in the domain. A body of the right length holding the
      wrong bytes is not this command's to find: the store checks that against
      the key it is filed under, and [tsync data-integrity] reads what it found.
  *)
  val resync :
    ?source:string ->
    ?scope:[ `All | `Manifests | `Path of string ] ->
    ?on_scan:(objects:int -> unit) ->
    ?on_list:(name:string -> unit) ->
    ?on_progress:(progress -> unit) ->
    ?on_copy:
      (name:string ->
      key:string ->
      reason:[ `Missing | `Wrong_size ] ->
      bytes:int ->
      unit) ->
    unit ->
    dest_stats list Lwt.t
end
