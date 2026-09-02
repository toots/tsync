(** Client-side folder-inode resolution, both ways round.

    Every folder in the local mirror carries a {!marker_name} file holding its
    stable backend id and its real name — the on-disk name may be escaped — in
    the same [{dir,name,id}] JSON as a backend folder marker ({!Folder}).

    The markers are filed under the path and so cannot answer id to path: each
    is mirrored by an entry under {!Cache_layout.folders_dir} holding the
    folder's parent id and real name, climbed to the root.

    Naming a folder goes through {!Layout.ensure_id} and so through
    {!Over.Make.write}, which writes the entry with the marker: whichever
    process writes the mirror keeps the index with it. {!Cache_layout.clear}
    empties both together, and filling the index again is {!Over.Make.rebuild},
    which the resync owes. *)

module type S = sig
  type 'a io

  (** The per-directory marker file naming that folder's id. *)
  val marker_name : string

  (** The folder's id, minting and persisting one when it has no marker yet. For
      the write paths, which may bring a folder into existence. *)
  val ensure_id :
    cache_root:string -> domain_name:string -> Logical_key.t -> string io

  (** The folder's id if this client already records one, [None] otherwise.

      What a read must use: minting here would persist a marker that re-creates
      the local directory, which is how a deleted folder comes back from a stat.
  *)
  val lookup_id :
    cache_root:string -> domain_name:string -> Logical_key.t -> string option io

  (** The id of a folder the mirror may already have dropped, for naming a
      removal. Separate from {!lookup_id} because a caller resolving something
      it means to reach must not be answered for a folder that is gone. *)
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

  (** Write a folder's marker, and the reverse entry that makes {!rel_of_id}
      answerable. *)
  val write :
    cache_root:string ->
    domain_name:string ->
    Logical_key.t ->
    Folder.marker ->
    unit io

  (** The domain-relative path of a folder id, or [None] when nothing records it
      — a folder that is gone, or an index emptied by {!Cache_layout.clear} and
      not yet rebuilt.

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

  (** Restate a folder's marker after it moved, taking the name from the new
      path. Every path that moves a directory locally owes this call, or the
      folder becomes unreachable by id. *)
  val reparent :
    cache_root:string -> domain_name:string -> Logical_key.t -> unit io

  (** Restate the whole reverse index from the markers, which are the truth. *)
  val rebuild : cache_root:string -> domain_name:string -> unit io
end

module Over (Io : Io.S) (_ : Fs.S with type 'a io := 'a Io.t) :
  S with type 'a io := 'a Io.t
