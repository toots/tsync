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
      [dest_stats] per destination, in configuration order. *)
  val resync : ?source:int -> unit -> dest_stats list Lwt.t
end
