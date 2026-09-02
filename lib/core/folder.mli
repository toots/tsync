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
