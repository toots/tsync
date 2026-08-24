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

(** What a listing of a namespace offers that is actually one of the folder's
    children. An empty namespace lists as its own directory key, a write in
    flight lists under a staging name, and the index caches the children rather
    than being one: none reads as a manifest, and each caller deciding that for
    itself is how three of them came to decide it differently. *)
val is_child_object : string -> bool
