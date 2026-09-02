(** Chunks a store found were not what their names say.

    What fails is filed under {!Chunk_layout.corrupted_prefix}, and that object
    {i is} the record, so reading the list is a listing of a prefix every
    backend already serves.

    There is no clearing operation: a marker is removed by whoever re-verifies
    the object, so a chunk nobody fixed cannot be marked clean by a client that
    merely believes it was. *)

type entry = {
  chunk_key : string;
  store : string;  (** the member holding the bad copy *)
}

(** [unverified] and [unreachable] are why this is not a bare list: zero markers
    out of a store nothing checked reads as a clean bill of health and is not
    one. *)
type report = {
  entries : entry list;
  unverified : string list;  (** members whose caps say nothing checks them *)
  unreachable : (string * string) list;  (** member name, why *)
}

module type S = sig
  type 'a io
  type store

  (** Every member, in role order. Not through {!Conf.S.store}: a composite
      serves a listing from whichever store answers first, so a chunk corrupt on
      one copy only would be reported or not depending on which that was. *)
  val list : unit -> report io

  (** One member, for a report that speaks per store. Raises whatever the store
      raised, rather than folding it into the answer: {!list} turns an
      unreachable store into a named line, while a health probe wants to say the
      probe itself failed, and those are not the same sentence.

      [max_keys] bounds the listing, so a store in real trouble reads as such
      rather than taking the report down with it. *)
  val member_entries :
    ?max_keys:int ->
    store Backend.member ->
    [ `Unverified | `Entries of entry list ] io

  (** What a marker records beyond existing — what the body hashed to, how big
      it was, when it was found. A separate round trip, for a caller that means
      to show it; the key alone is the finding. *)
  val detail : entry -> Corruption_marker.t option io

  (** {1 For the upload path}

      Whether a chunk is known bad, which an uploader must ask before letting
      dedup skip a write: a corrupt chunk is the right {i size}, so a presence
      check cannot tell it from a good one, and skipping the upload would leave
      the marker standing and hand the bad bytes to the next file that contains
      that chunk. *)

  (** Listed once and held for a few seconds, so a file's worth of chunks costs
      one request rather than one each. A listing that fails answers "nothing
      marked": an unreachable store must not be able to stop an upload. *)
  val is_marked : string -> bool io

  (** Drop a key from the memo after re-uploading it, so the rest of the session
      does not go on treating a chunk it has just rewritten as bad. *)
  val forget : string -> unit

  (** Re-list on the next ask. For a caller that has just changed what the store
      holds by some route this module cannot see. *)
  val invalidate : unit -> unit
end

(** The shape a consumer takes: {!S} for whichever domain it is applied to. *)
module type OVER = sig
  type 'a io

  module Make (C : Conf.S with type 'a io = 'a io) :
    S with type 'a io := 'a io and type store := (module C.Store)
end

module Over (Io : Io.S) : OVER with type 'a io := 'a Io.t
