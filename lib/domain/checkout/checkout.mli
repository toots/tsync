(** This client's working copy of the domain: every manifest the store has,
    filed under the file's real path so the tree can be walked without it, and
    over the top of that whatever {!Staged_manifest} says this client has
    changed.

    The published half is a projection — {!Cache_layout.clear} drops it and a
    resync rebuilds it — which is why the staged half it reads through is a
    store of its own. This module is where the two are put together: it owns the
    published tree, and the overlay is the only thing that consults both. *)

(** What the mirror knows is in a folder: the domain's name for an item, and the
    size and mtime held for it.

    Not a {!Backend.file_entry}: a store's listing answers with the key an
    object is filed under and its identity for the bytes, neither of which a
    mirror of names has — its keys are hashed, and it is asked what a folder
    contains, not what a bucket does. *)
type listed = { key : Logical_key.t; size : int; mtime : float }

(** True when [key] has unsynced edits, or the chunk store holds every cache
    chunk its sidecar's chunks group into. Synchronous, for the CLI listing;
    [false] for a partly cached file. *)
val is_local : Conf.locality -> Logical_key.t -> bool

module type S = sig
  type 'a io

  val rename : src_key:Logical_key.t -> dst_key:Logical_key.t -> unit io
  val create_dir : Logical_key.t -> unit io
  val delete_dir : Logical_key.t -> unit io

  (** Immediate children of [prefix]: file entries (logical keys, size, mtime)
      and real subdirectory names, serving both readdir and frontend
      enumeration.

      Internal markers are filtered, names are real rather than escaped, and a
      staged file's own size and mtime win — it is listed even when nothing of
      it has been published. *)
  val list_children :
    prefix:Logical_key.t -> unit -> (listed list * string list) io

  (** Every file entry under [prefix], recursively. *)
  val list_tree : prefix:Logical_key.t -> unit -> listed list io

  (** Domain-relative real path of every file the domain holds locally,
      published or only staged (unsorted). *)
  val walk : unit -> string list io

  (** Create the checkout root. Every process serving the domain needs this
      and nothing more. *)
  val ensure_root : unit -> unit io
end

(** The shape a consumer takes: {!S} for whichever domain it is applied to. *)
module type OVER = sig
  type 'a io

  module Make (C : Conf.S with type 'a io = 'a io) : S with type 'a io := 'a io
end

module Over
    (Io : Io.S)
    (Fs : Cache_layout.FS with type 'a io := 'a Io.t)
    (_ : Syscalls.S with type 'a io := 'a Io.t)
    (_ : Manifests.OVER with type 'a io := 'a Io.t)
    (_ : Staged_manifest.OVER with type 'a io := 'a Io.t)
    (_ : Folder_ids.S with type 'a io := 'a Io.t) :
  OVER with type 'a io := 'a Io.t
