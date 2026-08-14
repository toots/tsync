(** Chunks a store found were not what their names say.

    A chunk's key is the hash of its bytes, so a store can hold every object it
    takes against the name it arrived under and needs nothing else to do it.
    What fails is filed under {!Chunk_layout.corrupted_prefix}, and that object
    {i is} the record: reading the list is a listing of a prefix, which every
    backend already serves.

    Who writes them differs and nothing here cares: a [local] store checks as it
    takes the write, an s3 or gcs bucket in a function its own object-created
    event triggers. There is no clearing operation, and deliberately so — a
    marker is removed by whoever re-verifies the object, which happens on every
    re-upload, so a chunk that has been put right cannot stay accused and a
    chunk nobody fixed cannot be marked clean by a client that merely believes
    it. *)

type entry = {
  chunk_key : string;
  store : string;  (** the member holding the bad copy *)
}

(** [unverified] and [unreachable] are why this is not a bare list. "No corrupt
    chunks" out of a store nothing checks, or one nothing could reach, is not
    the same answer as "no corrupt chunks" out of a store that looked — and a
    report that prints them the same way is worse than one that says nothing,
    because it reads as a clean bill of health. *)
type report = {
  entries : entry list;
  unverified : string list;  (** members whose caps say nothing checks them *)
  unreachable : (string * string) list;  (** member name, why *)
}

module Make (C : Conf.S) : sig
  val prefix : string

  (** Every member, in role order. Not through {!Conf.S.store}: a composite
      serves a listing from whichever store answers first, so a chunk corrupt on
      one copy only would be reported or not depending on which that was. *)
  val list : unit -> report Lwt.t

  (** One member, for a report that speaks per store. Raises whatever the store
      raised, rather than folding it into the answer: {!list} turns an
      unreachable store into a named line, while a health probe wants to say the
      probe itself failed, and those are not the same sentence.

      [max_keys] bounds the listing, so a store in real trouble reads as such
      rather than taking the report down with it. *)
  val member_entries :
    ?max_keys:int ->
    Backend.member ->
    [ `Unverified | `Entries of entry list ] Lwt.t

  (** What a marker records beyond existing — what the body hashed to, how big
      it was, when it was found. A separate round trip, for a caller that means
      to show it; the key alone is the finding. *)
  val detail : entry -> Corruption_marker.t option Lwt.t

  (** {1 For the upload path}

      Whether a chunk is known bad, which an uploader must ask before letting
      dedup skip a write: a corrupt chunk is the right {i size}, so a presence
      check cannot tell it from a good one, and skipping the upload would leave
      the marker standing and hand the bad bytes to the next file that contains
      that chunk. *)

  (** Listed once and held for a few seconds, so a file's worth of chunks costs
      one request rather than one each. A listing that fails answers "nothing
      marked": an unreachable store must not be able to stop an upload. *)
  val is_marked : string -> bool Lwt.t

  (** Drop a key from the memo after re-uploading it, so the rest of the session
      does not go on treating a chunk it has just rewritten as bad. *)
  val forget : string -> unit

  (** Re-list on the next ask. For a caller that has just changed what the store
      holds by some route this module cannot see. *)
  val invalidate : unit -> unit
end
