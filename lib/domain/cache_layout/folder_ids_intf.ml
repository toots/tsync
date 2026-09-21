module type S = sig
  type 'a io

  (** The per-directory marker file naming that folder's id. *)
  val marker_name : string

  (** The folder's id if this client already records one, [None] otherwise.

      What a read must use: minting here would persist a marker that re-creates
      the local directory, which is how a deleted folder comes back from a stat.
  *)
  val lookup_id :
    cache_root:string -> domain_name:string -> Logical_key.t -> string option io

  (** The id a path names or last named, the folder having moved or gone since:
      for naming a removal, and for filing what an op recorded under that path.
      Separate from {!lookup_id} because a caller resolving something it means
      to reach must not be answered for a folder that is gone. *)
  val lookup_id_removed :
    cache_root:string -> domain_name:string -> Logical_key.t -> string option io

  (** The reference an item answers to, [None] for a folder this client cannot
      resolve. The inverse of what {!key_of_id} does for the daemon: a caller
      holding a path names the item before it asks anything over a socket. *)
  val ref_of_key :
    cache_root:string ->
    domain_name:string ->
    Logical_key.t ->
    Item_ref.t option io

  (** Write a folder's marker, and the reverse entry that makes {!key_of_id}
      answerable. A folder that already holds another id keeps it, and the
      answer names it: references to a folder never change under it. *)
  val write :
    cache_root:string ->
    domain_name:string ->
    Logical_key.t ->
    Folder.marker ->
    [ `Written | `Held of string ] io

  (** {!write}, whatever id the folder held: for a resync, which restates the
      store's tree over the mirror's. *)
  val replace :
    cache_root:string ->
    domain_name:string ->
    Logical_key.t ->
    Folder.marker ->
    unit io

  (** The domain-relative path of a folder id, or [None] when nothing records it
      — a folder that is gone, or an index not yet rebuilt from the markers.

      Climbs the index and holds the result against the markers before believing
      it, so a wrong entry costs an answer rather than naming another folder.
      Reads only: this is a request path, and a walk of the mirror is not one to
      spend there. Depth is unbounded, a chain that meets itself answering
      [None]. *)
  val key_of_id :
    cache_root:string ->
    domain_name:string ->
    root:Logical_key.t ->
    string ->
    Logical_key.t option io

  (** What this client knows of the folder a path names, or last named: there
      now, moved to another path since, removed since, or never held. One answer
      for every caller that meets a path an op recorded before the folder went.
  *)
  val whereabouts :
    cache_root:string ->
    domain_name:string ->
    root:Logical_key.t ->
    Logical_key.t ->
    [ `Live of string
    | `Moved of string * Logical_key.t
    | `Removed of string
    | `Unknown ]
    io

  (** Stop [key] and every folder under it being folders the store knows: their
      markers go, and so does the path [key] was named by, so neither a lookup
      nor the naming of a removal answers with an id another path holds. What
      the folders contain stays. *)
  val forget :
    cache_root:string -> domain_name:string -> Logical_key.t -> unit io

  (** Restate a folder's marker after it moved, taking the name from the new
      path. Every path that moves a directory locally owes this call, or the
      folder becomes unreachable by id. *)
  val reparent :
    cache_root:string -> domain_name:string -> Logical_key.t -> unit io

  (** Restate the whole reverse index from the markers, which are the truth. *)
  val rebuild : cache_root:string -> domain_name:string -> unit io
end
