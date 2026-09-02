(** Remote resync: bring one backend up to date from another, copying every
    object of the domain (manifests, chunks, journal, versions, cursor) that is
    missing or size-mismatched on the destination. *)

type dest_stats = {
  name : string;  (** the destination member's configured name *)
  checked : int;  (** source objects examined *)
  copied : int;
      (** Objects copied. A count rather than the keys: a first resync onto an
          empty destination copies the whole domain, and holding its keyspace as
          strings to print at the end is the resync's own memory. [on_entry]
          carries each key as it lands. *)
  copied_bytes : int;
}

(** Walking one folder of the backend's tree. *)
module type TREE = sig
  type 'a io
  type pool

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val children :
      ?on_unusable:Inode_tree.on_unusable ->
      ?refresh_index:bool ->
      ?on_index:(Stored_key.t -> unit) ->
      ?slots:pool ->
      folder_id:string ->
      unit ->
      Inode_tree.entry list io
  end
end

(** Whether a collection is under way, which decides where a chunk is read from.
*)
module type COLLECTION = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val read_run : unit -> Collection.run option io
    val string_of_phase : Collection.phase -> string
  end
end

module Over
    (Io : Io.S)
    (_ : Listing.SPOOL with type 'a io := 'a Io.t)
    (Pools : Bounded.S with type 'a io := 'a Io.t)
    (_ : TREE with type 'a io := 'a Io.t and type pool := Pools.t)
    (_ : COLLECTION with type 'a io := 'a Io.t) : sig
  module Make (C : Conf.S with type 'a io = 'a Io.t) : sig
    (** Copy from the {!Conf.members} entry named [source] (default the first,
        which role order makes a main) to every other one. Copies between the
        stores themselves rather than through {!Conf.store}: the point is to
        reach the ones the composite writes off the caller's path, or does not
        write at all. Additive only: objects deleted on the source are not
        deleted on the destinations. Returns one [dest_stats] per destination,
        in configuration order.

        Raises [Failure] when nothing has the name [source].

        [scope] selects what is copied:
        - [`All], every namespace plus the cursor;
        - [`Manifests], the manifests namespace alone ([C.domain_prefix],
          skipping chunks/journal/versions/cursor) — cheap way to complete a
          backend's structure without hauling chunk data;
        - [`Path rel], the files under the domain-relative folder [rel] and the
          chunks their manifests name, skipping journal/versions/cursor, which
          describe the domain rather than a subtree. Raises [Failure] when the
          source is missing an object the scope selected: this command copies a
          full backend onto a partial one, so that is the source being wrong.

        [on_list] fires before each step of working out what the source holds,
        [name] being that step phrased for a progress line. [on_scan] fires once
        after listing and before copying, with how many source objects are to be
        examined and how many bytes they come to — one destination's worth, the
        run being that times the number of destinations.

        [on_entry] fires once per object examined, per destination: [`Copied]
        with the bytes written and what was wrong with the destination's copy
        ([`Missing] or [`Wrong_size]), or [`Present] for one already right,
        which is most of them on any resync after the first. [size] is what the
        source listing said, and so what a plan counted the object as, which is
        not the bytes a copy moved should the object have changed since. A body
        of the right length holding the wrong bytes is not this command's to
        find: the store checks that against the key it is filed under, and
        [tsync data-integrity] reads what it found.

        [on_start] fires as each object is picked up, which is what a caller
        saying where the copy has got to wants: [on_entry] fires once an object
        is done, and a chunk spends its whole life between the two. Several
        objects are in flight at once, so the two do not pair up. *)
    val resync :
      ?source:string ->
      ?scope:[ `All | `Manifests | `Path of string ] ->
      ?on_scan:(objects:int -> bytes:int64 -> unit) ->
      ?on_list:(name:string -> unit) ->
      ?on_start:(name:string -> key:Stored_key.t -> unit) ->
      ?on_entry:
        (name:string ->
        key:Stored_key.t ->
        size:int ->
        outcome:[ `Copied of [ `Missing | `Wrong_size ] * int | `Present ] ->
        unit) ->
      unit ->
      dest_stats list Io.t
  end
end
