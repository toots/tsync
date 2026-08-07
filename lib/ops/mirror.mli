(** Remote resync: bring one backend up to date from another, copying every
    object of the domain (manifests, chunks, journal, versions, cursor) that is
    missing or size-mismatched on the destination. *)

type dest_stats = {
  index : int;  (** position of the destination in [C.backends] *)
  checked : int;  (** source objects examined *)
  copied : string list;  (** keys copied, sorted *)
  copied_bytes : int;
}

module Make (C : Conf.S) : sig
  (** Copy from the backend at position [source] in [C.backends] (default 0, the
      primary) to every other configured backend. Additive only: objects deleted
      on the source are not deleted on the destinations. Returns one
      [dest_stats] per destination, in configuration order.

      [manifests_only] restricts the copy to the manifests namespace
      ([C.domain_prefix], skipping chunks/journal/versions/cursor) — cheap way
      to complete a backend's structure without hauling chunk data.

      [on_list] fires before listing each source namespace ([name] is
      "manifests"/"chunks"/"journal"/"versions"). [on_scan] fires once with the
      total number of source objects to examine (after listing, before copying).
      [on_copy] fires per object actually copied, with the destination position
      and the bytes written — for live progress. *)
  val resync :
    ?source:int ->
    ?manifests_only:bool ->
    ?on_scan:(objects:int -> unit) ->
    ?on_list:(name:string -> unit) ->
    ?on_copy:(index:int -> key:string -> bytes:int -> unit) ->
    unit ->
    dest_stats list Lwt.t
end
