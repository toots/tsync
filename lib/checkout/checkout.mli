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

(** The local manifest mirror for one domain: where manifests live, how the tree
    is walked, and the parsed-sidecar cache. Callers name logical keys only — no
    cache paths, no domain prefixes, no raw bodies. *)
module Make (C : Conf.S) : sig
  val rename : src_key:Logical_key.t -> dst_key:Logical_key.t -> unit Lwt.t
  val create_dir : Logical_key.t -> unit Lwt.t
  val delete_dir : Logical_key.t -> unit Lwt.t

  (** Immediate children of [prefix]: file entries (logical keys, size, mtime)
      and real subdirectory names, serving both readdir and frontend
      enumeration.

      Internal markers are filtered, names are real rather than escaped, and a
      staged file's own size and mtime win — it is listed even when nothing of
      it has been published. *)
  val list_children :
    prefix:Logical_key.t -> unit -> (listed list * string list) Lwt.t

  (** Every file entry under [prefix], recursively. *)
  val list_tree : prefix:Logical_key.t -> unit -> listed list Lwt.t

  (** Domain-relative real path of every file the domain holds locally,
      published or only staged (unsorted). *)
  val walk : unit -> string list Lwt.t

  (** Create the checkout root. Every process serving the domain needs this and
      nothing more. *)
  val ensure_root : unit -> unit Lwt.t

  (** That, and drop the temp files a crash left behind.

      Once per machine, before anything serves. A temp name embeds the pid that
      made it, but the recogniser does not read it back and could not usefully:
      what matters is whether some process is still writing, not which one. So a
      second process running this unlinks the first one's temp file, and its
      rename then fails ENOENT. *)
  val reap_leftovers : unit -> unit Lwt.t
end
