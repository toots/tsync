(** Which manifest describes one file right now, and how to replace it.

    The mirror keyed one file at a time: what the store has published for it,
    what this client has staged over that, and the writing of either. The tree
    it all sits in — listings, directories, renames — is {!Checkout}, which is
    built on this. *)

module type S = sig
  type 'a io

  (** The directory the manifests of this domain are filed under. *)
  val root : unit -> string

  (** Where [key]'s manifest is filed. *)
  val path : Logical_key.t -> string

  (** Create the directory [key]'s manifest is filed in, and every one above it.
  *)
  val ensure_parent : Logical_key.t -> unit io

  (** What the store has published for [key], read through the mirror. Answers
      [None] for a key with no manifest filed. *)
  val published : Logical_key.t -> Manifest.t option io

  (** Sole writer of a manifest body in the cache. Stamps the name from the key,
      so a mirror manifest always records the name it is filed under. *)
  val write : Logical_key.t -> Manifest.t -> unit io

  val delete : Logical_key.t -> unit io

  (** The single resolution point, and no caller decides it itself: staged edits
      where this client has any, otherwise what was published. *)
  val current :
    Logical_key.t ->
    [ `Staged of Staged_manifest.staged * Manifest.t option
    | `Published of Manifest.t ]
    option
    io

  (** Drop what is remembered of [key], for a caller that moves a manifest by
      other means. A read re-checks the inode anyway, so this is for the cases
      that would otherwise re-read it needlessly. *)
  val forget : Logical_key.t -> unit

  (** How many manifests are remembered. For a test that pins the bound. *)
  val memo_size : unit -> int
end

(** The shape a consumer takes: {!S} for whichever domain it is applied to, and
    what stands beside it. *)
module type OVER = sig
  type 'a io

  (** Create [rel] under [root] and every directory above it, recording the real
      name beside any component the filesystem cannot hold verbatim. *)
  val ensure_dirs : string -> string -> unit io

  module Make (C : Conf.S with type 'a io = 'a io) : S with type 'a io := 'a io
end

module Over
    (Io : Io.S)
    (_ : Cache_layout.FS with type 'a io := 'a Io.t)
    (_ : Staged_manifest.OVER with type 'a io := 'a Io.t) :
  OVER with type 'a io := 'a Io.t
