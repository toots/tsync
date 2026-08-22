(** The backend's folder inode model.

    A directory is identified by a stable random id, not by its mutable name, so
    renaming or moving one rewrites only the parent's marker entry and never its
    descendants, whose keys live under [manifests/<id>/…].

    Two kinds of object live at [manifests/<folder id>/<hash of child name>] — a
    file manifest, or a folder marker naming a child directory and the namespace
    holding its children — told apart only by their body, which is what
    {!marker_of_string} is for. *)

(** The root namespace. Reserved ids carry the [.tsync-] sentinel, so they never
    collide with a folder id (random hex) and read as internal. *)
val root_id : string

(** Where a deleted folder's marker is moved: unreachable from the root, so the
    subtree vanishes from listings and resync until [expire] drops it past a
    grace period. *)
val trash_id : string

(** A fresh folder id, minted at mkdir. *)
val new_id : unit -> string

(** Manifests-relative key of [name] within [folder_id]'s namespace. Fixed
    length and filesystem-safe whatever the real name is. *)
val child_key : folder_id:string -> string -> string

(** A folder's own cache of its children's bodies, filed inside the namespace it
    describes: it is then listed alongside them, so finding it costs no round
    trip of its own, and deleting the folder takes it too.

    The [.tsync-] sentinel keeps it clear of a child key, which is always a pair
    of hex hashes. *)
val index_key : folder_id:string -> string

val is_index_key : string -> bool

(** Whether a key a namespace listing offered is one of the folder's children.

    Three things it can offer that are not: the directory key an empty namespace
    lists as, a local write in flight under its staging name, and the folder's
    own {!index_key}. None of them reads as a manifest or a marker, and a caller
    that fetches one gets a failure or a body it cannot classify — which for a
    resync is a child it could not read, and for a collection is a run that
    stops with nothing discarded. *)
val is_child_object : string -> bool

type marker = { name : string; id : string }

val marker_to_string : marker -> string

(** A trashed folder's marker also records its original path, so it can be
    listed and restored. The extra field is ignored by {!marker_of_string}. *)
val trash_marker_to_string : name:string -> id:string -> path:string -> string

(** The [path] a trashed marker recorded, or [None] if it has none. *)
val trash_path_of_string : string -> string option

(** [Some marker] when the body is a folder marker, [None] when it is a file
    manifest or cannot be parsed. *)
val marker_of_string : string -> marker option
