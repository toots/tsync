(** What copying one entry comes to, decided before anything is done about it.

    Deciding is separate from acting because the cheap answers are the point: a
    file whose chunks this domain already holds is published, not moved, however
    large it is. *)

type local = {
  size : int64;
  mtime : float;
  keys : string array option;
      (** Chunk keys of the bytes on disk, cut at the manifest's chunk size so
          that index [i] names the same span on both sides. Gathered only where
          a caller asked for it: hashing a file costs what the answer saves. *)
  link : string option;
      (** What a symlink points at, which is the whole of its content and the
          only thing worth comparing it by. *)
}

type side = [ `Local | `Domain ]
type source = [ `Missing | `Dir | `File of local | `Key of Manifest.t ]

(** A destination that does not exist is still one side or the other, and which
    one says whether the answer is a manifest publish or a local write. *)
type target =
  [ `Absent of side | `Dir of side | `File of local | `Key of Manifest.t ]

type skip =
  [ `Source_missing
  | `Identical
  | `Target_is_dir
  | `Target_not_a_dir
  | `Not_in_domain  (** neither end is in a domain, which is plain rsync's job *)
  ]

type t =
  | Skip of skip
  | Make_dir of side
  | Rename_in_domain
      (** A move within the domain onto nothing: one journal op, no publish. *)
  | Copy_manifest of Manifest.t
      (** The source's chunks are already in this domain's chunk space, so
          publishing its key list under the destination key is the whole copy.
      *)
  | Upload of [ `Fresh | `Replacing ]
      (** Local to domain, where the store keeps only the chunks it lacks and
          the differing ones are therefore exactly what is sent. *)
  | Assemble of Manifest.t  (** Domain to local, whole file. *)
  | Patch_local of { src : Manifest.t; chunks : int list }
      (** Domain to local, fetching these chunk indices and no others. *)

val decide : move:bool -> src:source -> target -> t

(** A short label for one decision, for a caller reporting a run. *)
val describe : t -> string

(** Whether the source survives the action. *)
val source_disposal : move:bool -> t -> [ `Keep | `Drop ]

(** Captured before the functor parameter of the same name shadows it. *)
type listed = Checkout.listed = {
  key : Logical_key.t;
  size : int;
  mtime : float;
}

module type FS = sig
  type 'a io

  val mkdir_p : string -> unit io
  val ensure_parent : string -> unit io
  val unlink_quiet : string -> unit io
  val readdir_list : string -> string list io
  val read : string -> Bigstring.t -> offset:int64 -> int io
  val stat_opt_large : string -> Unix.LargeFile.stats option io

  val lstat_kind :
    string -> [ `Dir | `File of int64 | `Symlink of string | `Missing ] io
end

module type SYSCALLS = sig
  type 'a io

  val symlink : ?to_dir:bool -> string -> string -> unit io
  val utimes : string -> float -> float -> unit io
  val lstat : string -> Unix.stats io
end

module type FOLDER_IDS = sig
  type 'a io

  val ensure_id :
    cache_root:string -> domain_name:string -> Logical_key.t -> string io
end

module type OBJECTS = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val chunk_size : unit -> int io

    val upload :
      key:Logical_key.t ->
      src_path:string ->
      mtime:float ->
      chunk_size:int ->
      ?cancel:bool ref ->
      ?on_progress:(bytes:int -> sent:bool -> unit) ->
      unit ->
      Manifest.t io

    val upload_chunks :
      key:Logical_key.t ->
      size:int64 ->
      chunk_size:int ->
      mtime:float ->
      source:(int -> unit io Chunk_source.t io) ->
      ?cancel:bool ref ->
      unit ->
      Manifest.t io

    val fetch_manifest : key:Logical_key.t -> unit -> Manifest.t option io
  end
end

module type MANIFESTS = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val put_manifest : key:Logical_key.t -> data:Bigstring.t -> unit io
    val put_folder_marker : key:Logical_key.t -> unit io
    val delete_manifest : key:Logical_key.t -> unit io
  end
end

module type JOURNAL = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val write_journal_entry_body :
      ?entry_key:Journal.Entry_key.t -> Bigstring.t -> Journal.Entry_key.t io

    val bump_cursor : Journal.Entry_key.t -> unit io
    val flush_cursor : unit -> unit io
  end
end

module type MIRROR = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val published : Logical_key.t -> Manifest.t option io
    val write : Logical_key.t -> Manifest.t -> unit io
    val delete : Logical_key.t -> unit io
  end
end

module type CHECKOUT = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val create_dir : Logical_key.t -> unit io

    val list_children :
      prefix:Logical_key.t -> unit -> (listed list * string list) io
  end
end

module type CONTENT = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val assemble_to : Logical_key.t -> dst_path:string -> unit io

    val fetch_range :
      Logical_key.t -> dst_path:string -> offset:int -> length:int -> int io
  end
end

(** One end of the copy, named the way the command's caller named it. *)
type endpoint = Local of string | Domain of string

type outcome = Copied of int64 | Skipped of skip | Made_dir | Failed of string

type summary = {
  copied : int;
  skipped : int;
  dirs : int;
  failed : int;
  bytes_moved : int64;
}

module Over
    (Io : Io.S)
    (_ : FS with type 'a io := 'a Io.t)
    (_ : SYSCALLS with type 'a io := 'a Io.t)
    (_ : FOLDER_IDS with type 'a io := 'a Io.t)
    (_ : OBJECTS with type 'a io := 'a Io.t)
    (_ : MANIFESTS with type 'a io := 'a Io.t)
    (_ : JOURNAL with type 'a io := 'a Io.t)
    (_ : MIRROR with type 'a io := 'a Io.t)
    (_ : CHECKOUT with type 'a io := 'a Io.t)
    (_ : CONTENT with type 'a io := 'a Io.t) : sig
  module Make (C : Conf.S with type 'a io = 'a Io.t) : sig
    (** Copy every entry under [src] to [dst], deciding per entry what that
        comes to. [move] drops each source once its destination is published,
        and takes the rename where both ends are in one domain. [checksum]
        hashes local files so a comparison against a manifest is by content
        rather than by size and mtime. *)
    val run :
      ?move:bool ->
      ?checksum:bool ->
      ?dry_run:bool ->
      ?on_entry:(rel:string -> t -> unit) ->
      src:endpoint ->
      dst:endpoint ->
      unit ->
      summary Io.t
  end
end
