(** The backend's folder inode model.

    A directory is identified by a stable random id, not by its mutable name, so
    renaming or moving one never rewrites its descendants: their keys live under
    [manifests/<id>/…] and that id never changes. Only the parent's marker entry
    is updated.

    Two kinds of object live at [manifests/<folder id>/<hash of child name>] — a
    file manifest, or a folder marker that both names a child directory and
    points at the namespace holding its children. They are told apart only by
    their body, which is what {!marker_of_string} is for. *)

(** The root namespace. Reserved ids carry the [.tsync-] sentinel, so they never
    collide with a folder id (random hex) and read as internal. *)
val root_id : string

(** Where a deleted folder's marker is moved: unreachable from the root, so the
    subtree vanishes from listings and resync, and [expire] drops it past a
    grace period — after which [gc] reclaims the chunks it was holding. *)
val trash_id : string

(** A fresh folder id, minted at mkdir. *)
val new_id : unit -> string

(** Manifests-relative key of [name] within [folder_id]'s namespace. Fixed
    length and filesystem-safe whatever the real name is. *)
val child_key : folder_id:string -> string -> string

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
