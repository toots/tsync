(** This client's working copy of the domain: every manifest the store has,
    filed under the file's real path so the tree can be walked without it, and
    over the top of that whatever {!Staged_manifest} says this client has
    changed.

    The published half is a projection — {!Cache_layout.clear} drops it and a
    resync rebuilds it — which is why the staged half it reads through is a
    store of its own. This module is where the two are put together: it owns the
    published tree, and the overlay is the only thing that consults both. *)

(** True when [key] has unsynced edits, or the chunk store holds every cache
    chunk its sidecar's chunks group into. Synchronous, for the CLI listing;
    [false] for a partly cached file. *)
val is_local : Conf.locality -> string -> bool

(** The local manifest mirror for one domain: where manifests live, how the tree
    is walked, and the parsed-sidecar cache. Callers name logical keys only — no
    cache paths, no domain prefixes, no raw bodies. *)
module Make (C : Conf.S) : sig
  (** On-disk path of [key]'s sidecar. Its inode doubles as the existence and
      directory test, since directories exist only in this tree. *)
  val path : Logical_key.t -> string

  (** What the store last published for [key], as this client last saw it:
      parsed from the sidecar and memoised. [None] when absent or unparseable.

      Says nothing about staged edits — {!current} is the question that weighs
      those. *)
  val published : Logical_key.t -> Manifest.t option Lwt.t

  (** Manifests held from earlier reads. A cached one keeps the mapping it was
      read through, so this counts live mappings rather than bytes, and it is
      bounded. Exposed because that bound is invisible from {!published}, which
      answers the same whether it was served from the cache or the file. *)
  val memo_size : unit -> int

  (** Writes [t] under [key], recording the name [key] encodes. A caller cannot
      file a manifest under one name and have it record another. *)
  val write : Logical_key.t -> Manifest.t -> unit Lwt.t

  val delete : Logical_key.t -> unit Lwt.t
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
    prefix:Logical_key.t ->
    unit ->
    (Backend.file_entry list * string list) Lwt.t

  (** Every file entry under [prefix], recursively. *)
  val list_tree : prefix:Logical_key.t -> unit -> Backend.file_entry list Lwt.t

  (** Domain-relative real path of every file the domain holds locally,
      published or only staged (unsorted). *)
  val walk : unit -> string list Lwt.t

  (** What the file is right now on this machine, staged edits winning over what
      was last published, with the published manifest alongside for the chunks a
      staged record inherits. This module owns that precedence; no caller
      decides it.

      Local only. A caller that must also reach the store for a key this client
      has never cached wants {!Data.published}, layered over this — which is
      what {!File_ops.stat} does. *)
  val current :
    Logical_key.t ->
    [ `Staged of Staged_manifest.staged * Manifest.t option
    | `Published of Manifest.t ]
    option
    Lwt.t

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
