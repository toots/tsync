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

      Each child costs a fetch, so they are taken under [slots] — the domain's
      download budget unless a caller passes a bound of its own, which is how
      [tsync sync --full] honours [--parallelism]. A pool passed here must
      outlive the call and must not be one the fold body asks again. *)
  val children :
    ?on_unusable:on_unusable ->
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
    ?slots:Lwt_bounded.t ->
    folder_id:string ->
    rel:string ->
    ('a -> string -> entry -> 'a Lwt.t) ->
    'a ->
    'a Lwt.t
end
