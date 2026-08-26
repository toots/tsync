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

(** What this needs below it. *)
module type FS = sig
  type 'a io

  val mkdir_p : string -> unit io
  val is_directory : string -> bool io
  val readdir_list : string -> string list io
  val atomic_write : string -> string -> unit io
  val rm_rf : string -> unit io
  val unlink_quiet : string -> unit io
  val real_dir_name : string -> string -> string io
end

module type SYSCALLS = sig
  type 'a io

  val file_exists : string -> bool io
  val rename : string -> string -> unit io
end

module type MIRROR = sig
  type 'a io

  module Make (_ : Conf.S) : sig
    val root : unit -> string
    val path : Logical_key.t -> string
    val ensure_parent : Logical_key.t -> unit io
    val write : Logical_key.t -> Manifest.t -> unit io
    val forget : Logical_key.t -> unit
  end

  val ensure_dirs : string -> string -> unit io
end

module type STAGED = sig
  type 'a io

  module Make (_ : Conf.S) : sig
    val fold :
      rel_dir:string ->
      deep:bool ->
      ('a -> Logical_key.t -> Staged_manifest.staged -> 'a) ->
      'a ->
      'a io

    val entries :
      rel_dir:string ->
      deep:bool ->
      (Logical_key.t * Staged_manifest.staged) list io
  end
end

module type FOLDERS = sig
  type 'a io

  val reparent :
    cache_root:string -> domain_name:string -> Logical_key.t -> unit io
end

module Over
    (Io : Io.S)
    (Fs : FS with type 'a io := 'a Io.t)
    (_ : SYSCALLS with type 'a io := 'a Io.t)
    (_ : MIRROR with type 'a io := 'a Io.t)
    (_ : STAGED with type 'a io := 'a Io.t)
    (_ : FOLDERS with type 'a io := 'a Io.t) : sig
  (** The local manifest mirror for one domain: where manifests live, how the
      tree is walked, and the parsed-sidecar cache. Callers name logical keys
      only — no cache paths, no domain prefixes, no raw bodies. *)
  module Make (C : Conf.S) : sig
    val rename : src_key:Logical_key.t -> dst_key:Logical_key.t -> unit Io.t
    val create_dir : Logical_key.t -> unit Io.t
    val delete_dir : Logical_key.t -> unit Io.t

    (** Immediate children of [prefix]: file entries (logical keys, size, mtime)
        and real subdirectory names, serving both readdir and frontend
        enumeration.

        Internal markers are filtered, names are real rather than escaped, and a
        staged file's own size and mtime win — it is listed even when nothing of
        it has been published. *)
    val list_children :
      prefix:Logical_key.t -> unit -> (listed list * string list) Io.t

    (** Every file entry under [prefix], recursively. *)
    val list_tree : prefix:Logical_key.t -> unit -> listed list Io.t

    (** Domain-relative real path of every file the domain holds locally,
        published or only staged (unsorted). *)
    val walk : unit -> string list Io.t

    (** Create the checkout root. Every process serving the domain needs this
        and nothing more. *)
    val ensure_root : unit -> unit Io.t

    (** That, and drop the temp files a crash left behind.

        Once per machine, before anything serves. A temp name embeds the pid
        that made it, but the recogniser does not read it back and could not
        usefully: what matters is whether some process is still writing, not
        which one. So a second process running this unlinks the first one's temp
        file, and its rename then fails ENOENT. *)
    val reap_leftovers : unit -> unit Io.t
  end
end
