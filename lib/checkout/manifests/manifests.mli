(** Which manifest describes one file right now, and how to replace it.

    The mirror keyed one file at a time: what the store has published for it,
    what this client has staged over that, and the writing of either. The tree
    it all sits in — listings, directories, renames — is {!Checkout}, which is
    built on this. *)

(** What this needs of a filesystem, and of the marker the layout keeps beside a
    directory. *)
module type FILES = sig
  type 'a io

  val mkdir_p : string -> unit io
  val stat_opt : string -> Unix.stats option io
  val unlink_quiet : string -> unit io

  val atomic_write_at :
    string ->
    size:int ->
    ((offset:int -> Bigstring.t -> unit io) -> unit io) ->
    unit io

  val record_dir_name : string -> string -> unit io
end

(** What this needs of the staged half: the edits a client has over the
    published manifest, if any. *)
module type STAGED = sig
  type 'a io

  module Make (_ : Conf.S) : sig
    val read_edits : Logical_key.t -> Staged_manifest.staged option io
  end
end

module Over
    (Io : Io.S)
    (_ : FILES with type 'a io := 'a Io.t)
    (_ : STAGED with type 'a io := 'a Io.t) : sig
  (** Create [rel] under [root] and every directory above it, recording the real
      name beside any component the filesystem cannot hold verbatim. *)
  val ensure_dirs : string -> string -> unit Io.t

  module Make (C : Conf.S) : sig
    (** The directory the manifests of this domain are filed under. *)
    val root : unit -> string

    (** Where [key]'s manifest is filed. *)
    val path : Logical_key.t -> string

    (** Create the directory [key]'s manifest is filed in, and every one above
        it. *)
    val ensure_parent : Logical_key.t -> unit Io.t

    (** What the store has published for [key], read through the mirror. Answers
        [None] for a key with no manifest filed. *)
    val published : Logical_key.t -> Manifest.t option Io.t

    (** Sole writer of a manifest body in the cache. Stamps the name from the
        key, so a mirror manifest always records the name it is filed under. *)
    val write : Logical_key.t -> Manifest.t -> unit Io.t

    val delete : Logical_key.t -> unit Io.t

    (** The single resolution point, and no caller decides it itself: staged
        edits where this client has any, otherwise what was published. *)
    val current :
      Logical_key.t ->
      [ `Staged of Staged_manifest.staged * Manifest.t option
      | `Published of Manifest.t ]
      option
      Io.t

    (** Drop what is remembered of [key], for a caller that moves a manifest by
        other means. A read re-checks the inode anyway, so this is for the cases
        that would otherwise re-read it needlessly. *)
    val forget : Logical_key.t -> unit

    (** How many manifests are remembered. For a test that pins the bound. *)
    val memo_size : unit -> int
  end
end
