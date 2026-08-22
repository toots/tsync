(** Reading the backend's folder tree: from a folder id to its children,
    classified.

    Under the inode layout every child of a folder lives at
    [manifests/<folder_id>/<hash(name)>] and is either a folder marker or a file
    manifest, told apart only by its body. This is the one place that fetches
    and classifies them. *)

type body = Dir of Folder.marker | File of Manifest.t
type entry = { bkey : string; body : body }

(** Why a child yielded no {!entry}: it could not be fetched, or its body is
    neither a marker nor a clean manifest, which is what a write in flight looks
    like. [`Unclassifiable] carries the parse failure, since that is the only
    account of what the body was. *)
type unusable = [ `Unreadable of exn | `Unclassifiable of exn ]

(** What a child that yields no entry costs the walk. [`Fail] propagates the
    fetch error, so a caller deciding what to delete cannot mistake it for an
    absent subtree; [`Skip f] carries on, telling [f] what was passed over.

    Reported rather than merely skipped because callers disagree about what a
    skip means: a resync that parsed nothing has to say so rather than claiming
    success, while a listing that only renders what it found does not care. An
    unclassifiable body is skipped under both, being mid-write. *)
type on_unusable = [ `Fail | `Skip of string -> unusable -> unit ]

module Make (C : Conf.S) : sig
  (** The backend prefix a folder's children live under. *)
  val namespace_prefix : string -> string

  (** Direct children of [folder_id], [`Fail] by default.

      One listing, then whatever {!Folder_index} does not already hold, read in
      one request where the store has a way to make one. [slots] bounds those
      reads — the domain's download budget unless a caller passes a bound of its
      own, which is how [tsync sync --full] honours [--parallelism]. A pool
      passed here must outlive the call and must not be one the fold body asks
      again.

      [refresh_index] writes the folder's index back when enough of it was not
      covered to pay for the round trip, and is for a caller that walks the tree
      and may write: a read-only domain and a share being served must leave it
      alone. Best effort either way — a read does not fail because its cache
      could not be refreshed. *)
  val children :
    ?on_unusable:on_unusable ->
    ?refresh_index:bool ->
    ?slots:Lwt_bounded.t ->
    folder_id:string ->
    unit ->
    entry list Lwt.t

  (** Depth-first over the subtree under [folder_id]. [f acc rel entry] sees
      each entry with the real relative path of the folder holding it, [rel]
      naming that starting folder. A folder is visited before it is descended
      into. *)
  val fold_tree :
    ?on_unusable:on_unusable ->
    ?refresh_index:bool ->
    ?slots:Lwt_bounded.t ->
    folder_id:string ->
    rel:string ->
    ('a -> string -> entry -> 'a Lwt.t) ->
    'a ->
    'a Lwt.t
end
