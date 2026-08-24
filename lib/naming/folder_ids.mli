(** Client-side folder-inode resolution, both ways round.

    Every folder in the local mirror carries a {!marker_name} file holding its
    stable backend id and its real name — the on-disk name may be escaped — in
    the same [{dir,name,id}] JSON as a backend folder marker ({!Folder}).

    The markers are filed under the path and so cannot answer id to path: each
    is mirrored by an entry under {!Cache_layout.folders_dir} holding the
    folder's parent id and real name, climbed to the root. Those entries hold
    nothing the markers do not, so a lookup finding one missing or disagreeing
    rebuilds them and retries, which is what makes the mirror tolerable to write
    from another process ([tsync import], [tsync sync --full]). *)

(** The per-directory marker file naming that folder's id. *)
val marker_name : string

(** The folder's id, minting and persisting one when it has no marker yet. For
    the write paths, which may bring a folder into existence. *)
val ensure_id :
  cache_root:string -> domain_name:string -> Logical_key.t -> string Lwt.t

(** The folder's id if this client already records one, [None] otherwise.

    What a read must use: minting here would persist a marker that re-creates
    the local directory, which is how a deleted folder comes back from a stat.
*)
val lookup_id :
  cache_root:string ->
  domain_name:string ->
  Logical_key.t ->
  string option Lwt.t

(** Write a folder's marker, and the reverse entry that makes {!rel_of_id}
    answerable. *)
val write :
  cache_root:string ->
  domain_name:string ->
  Logical_key.t ->
  Folder.marker ->
  unit Lwt.t

(** The domain-relative path of a folder id, or [None] when nothing records it.
    A miss rebuilds the reverse index once and retries before answering. *)
val key_of_id :
  cache_root:string ->
  domain_name:string ->
  root:Logical_key.t ->
  string ->
  Logical_key.t option Lwt.t

(** Restate a folder's marker after it moved, taking the name from the new path.
    Every path that moves a directory locally owes this call, or the folder
    becomes unreachable by id. *)
val reparent :
  cache_root:string -> domain_name:string -> Logical_key.t -> unit Lwt.t

(** Restate the whole reverse index from the markers, which are the truth. *)
val rebuild : cache_root:string -> domain_name:string -> unit Lwt.t
