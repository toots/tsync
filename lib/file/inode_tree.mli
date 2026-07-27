(** Reading the backend's folder tree: from a folder id to its children,
    classified.

    Under the inode layout every child of a folder lives at
    [manifests/<folder_id>/<hash(name)>] and is either a folder marker or a file
    manifest, told apart only by its body. This is the one place that fetches
    and classifies them. *)

type body = Dir of Folder.marker | File of Manifest.t
type entry = { bkey : string; body : body }

module Make (C : Conf.S) : sig
  (** The backend prefix a folder's children live under. *)
  val namespace_prefix : string -> string

  (** Direct children of [folder_id]. Objects that are neither a marker nor a
      clean manifest are skipped — they are mid-write. With [skip_errors], a
      child that cannot be fetched is skipped as well; the default propagates,
      so a caller deciding what to delete cannot mistake a failed fetch for an
      absent subtree. *)
  val children :
    ?skip_errors:bool -> folder_id:string -> unit -> entry list Lwt.t

  (** Depth-first over the subtree under [folder_id]. [f acc rel entry] sees
      each entry with the real relative path of the folder holding it, [rel]
      naming that starting folder. A folder is visited before it is descended
      into. *)
  val fold_tree :
    ?skip_errors:bool ->
    folder_id:string ->
    rel:string ->
    ('a -> string -> entry -> 'a Lwt.t) ->
    'a ->
    'a Lwt.t
end
