(** How a store names an item, given the folder it sits in.

    A folder has an id that a rename does not touch, and its children are filed
    under that id by a hash of their leaf name — so moving a folder moves
    nothing beneath it, and the name a child was given survives only in the body
    filed there.

    Which id a {!Logical_key.t} belongs to is not answerable here: it needs the
    map from paths to ids, and stays {!Layout}'s. *)
(** Whether a leaf is one a store keeps for itself. Every such name shares one
    prefix, so no store enumerates them and none can answer this differently. *)
val reserved : string -> bool

val root_id : string

(** Where a deleted folder's marker moves: unreachable from the root, so the
    subtree leaves listings and resync until [expire] drops it. Both reserved
    ids share the [.tsync-] sentinel used for internal markers, so neither
    collides with a folder id, which is random hex. *)
val trash_id : string

(** Minted at mkdir. *)
val new_id : unit -> string

(** {1 The name itself}

    A store keeps several spaces — manifests, chunks, versions, journal, shares
    — and a key is a path within one of them. Both halves are given together, so
    a path that could be filed anywhere never exists on its own.

    There is no [of_string]: a key is here because a namer built it, or because
    a store said it has one. *)

type t

val to_string : t -> string

(** A path within the space [prefix] names, for that space's owner. *)
val in_space : prefix:string -> string -> t

(** A key a store reported, taken at its word. *)
val listed : string -> t

(** Where a folder files its children, which is also what a listing of the
    folder walks. *)
val namespace : prefix:string -> folder_id:string -> t

(** A name inside a key that already spells a namespace. *)
val under : t -> string -> t

(** Where deleted folders' markers are filed, in the manifests space. *)
val trash_namespace : prefix:string -> t

(** A share, filed by its token alone: that is what keeps the link short, and
    what makes a hex token unable to address anything outside the share
    space. *)
val share_key : prefix:string -> string -> t

(** Where a folder's child of this name is filed. *)
val child_key : prefix:string -> folder_id:string -> string -> t

(** A folder's cache of its children's bodies, filed inside the namespace it
    describes so it is listed with them and dies with them. *)
val index_key : prefix:string -> folder_id:string -> t

val is_index_key : string -> bool

(** An object written under a staging name, which a rename will replace with the
    real one. *)
val is_temp_key : string -> bool

(** {1 A mirror's spelling}

    A store that files an item under its real path — this client's manifest
    mirror — has to hand each component to a filesystem, and a filesystem will
    not hold every name a user can type. A component too long, carrying a
    character some filesystem refuses, or {!reserved} is replaced by a
    fixed-length handle.

    Reserved covers every name a store keeps for itself, so a file a user called
    [.tsync-dir] is stored as a handle rather than read back as a marker.

    A handle is lossy, so the real name is recovered elsewhere: for a file from
    its manifest body, for a directory from a marker beside it. *)

(** One component, as itself where it can be stored and hashed where it cannot. *)
val escape : string -> string

(** {!escape} over every component of a relative path. *)
val escape_path : string -> string

(** Whether a component is a handle rather than a name someone chose. *)
val is_escaped : string -> bool

(** The leaf naming what an escaped directory is really called. *)
val dir_name_leaf : string

(** The leaf naming which folder id a directory has. *)
val folder_marker_leaf : string

(** A namespace listed as itself, which every store does for a folder: it names
    no object, so a reader wanting bodies passes over it and a copy writes an
    empty one to keep the folder. *)
val is_dir_key : string -> bool

(** The folder a namespace key names, which is the id {!child_key} filed its
    children under. *)
val folder_id_of : string -> string

(** The inverse of {!in_space}: the path this key has within the space, for a
    caller re-rooting it elsewhere — a version of a manifest is the manifest's
    own key under another prefix, so the two share the folder id a rename does
    not touch. Unchanged for a key that is not in that space. *)
val path_in : prefix:string -> t -> string

(** The store's own bookkeeping rather than anything a domain named — a write in
    flight, a folder's index of its children, a mirror's markers. Nothing
    outside this store should be given one. *)
val is_internal : string -> bool

(** What a listing of a namespace offers that is actually one of the folder's
    children: neither the namespace itself nor the store's bookkeeping. A copy
    of a namespace asks {!is_internal} instead, the directory key being part of
    what it has to carry. *)
val is_child_object : string -> bool
