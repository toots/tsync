(** The backend's folder inode model.

    A directory is identified by a stable random id, not by its mutable name, so
    renaming or moving one rewrites only the parent's marker entry and never its
    descendants, whose keys live under [manifests/<id>/…].

    Two kinds of object live at [manifests/<folder id>/<hash of child name>] — a
    file manifest, or a folder marker naming a child directory and the namespace
    holding its children — told apart only by their body, which is what
    {!marker_of_string} is for. *)

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

(** Where a folder lives, kept inside its own namespace at
    {!Stored_key.anchor_key}: the id of the folder holding it and its name
    there. The marker under the parent says the same from the other side; when a
    marker and the anchor disagree, the marker is stale, which is how a marker a
    move left behind is told from the folder's real place. *)
type anchor = { parent : string; name : string }

val anchor_to_string : anchor -> string

(** [None] for anything that is not an anchor, a marker included. *)
val anchor_of_string : string -> anchor option
