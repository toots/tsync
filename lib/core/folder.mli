(** Folder markers, anchors and trash entries (spec 02 §2.7–2.9). *)

(** "the folder [id] appears here under [name]" *)
type marker = { name : string; id : Folder_id.t }

(** Where a folder says it lives; the authority between markers. *)
type anchor = { parent : Folder_id.t; aname : string }

(** Exactly [{"dir":true,"name":…,"id":…}]. *)
val marker_body : marker -> string

(** A marker body plus the path at deletion time. *)
val trash_body : marker -> path:string -> string

val anchor_body : anchor -> string

(** A marker (with the trash entry's path, if any), a marker whose id is not a
    folder id, or not a marker at all. *)
val classify_marker :
  string -> [ `Marker of marker * string option | `Unclassifiable | `Not_marker ]

(** [None] unless both fields are strings and the parent is a folder id. *)
val decode_anchor : string -> anchor option

val in_trash : anchor -> bool
