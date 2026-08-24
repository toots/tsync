(** How a store names an item, given the folder it sits in.

    A folder has an id that a rename does not touch, and its children are filed
    under that id by a hash of their leaf name — so moving a folder moves
    nothing beneath it, and the name a child was given survives only in the body
    filed there.

    Which id a {!Logical_key.t} belongs to is not answerable here: it needs the
    map from paths to ids, and stays {!Layout}'s. *)
val root_id : string

(** Where a deleted folder's marker moves: unreachable from the root, so the
    subtree leaves listings and resync until [expire] drops it. Both reserved
    ids share the [.tsync-] sentinel used for internal markers, so neither
    collides with a folder id, which is random hex. *)
val trash_id : string

(** Minted at mkdir. *)
val new_id : unit -> string

(** Where a folder's child of this name is filed. *)
val child_key : folder_id:string -> string -> string

(** A folder's cache of its children's bodies, filed inside the namespace it
    describes so it is listed with them and dies with them. *)
val index_key : folder_id:string -> string

val is_index_key : string -> bool

(** An object written under a staging name, which a rename will replace with the
    real one. Reserved names all share the [.tsync-] sentinel. *)
val is_temp_key : string -> bool

(** A namespace listed as itself, which every store does for a folder: it names
    no object, so a reader wanting bodies passes over it and a copy writes an
    empty one to keep the folder. *)
val is_dir_key : string -> bool

(** The folder a namespace key names, which is the id {!child_key} filed its
    children under. *)
val folder_id_of : string -> string

(** A key with the domain root taken off, for a caller re-rooting it elsewhere —
    a version of a manifest is the manifest's own key under another prefix, so
    the two share the folder id a rename does not touch. Unchanged for a key
    that does not carry the prefix. *)
val strip_domain : domain_prefix:string -> string -> string

(** The store's own bookkeeping rather than anything a domain named — a write in
    flight under a staging name, or a folder's index of its children. Nothing
    outside this store should be given one. *)
val is_internal : string -> bool

(** What a listing of a namespace offers that is actually one of the folder's
    children: neither the namespace itself nor the store's bookkeeping. A copy
    of a namespace asks {!is_internal} instead, the directory key being part of
    what it has to carry. *)
val is_child_object : string -> bool
