(** A filesystem, as far as anything above it needs one.

    Most of what is here is not a syscall: a recursive mkdir, a temp-and-rename,
    a walk that removes a tree. {!Make} writes that once against {!Io.S} and the
    few operations a platform actually owes, which is {!PRIMITIVES}. *)

(** {!Make}'s [mkdir_p] for callers running before there is a loop to run in:
    process startup, the CLI, the config writer. *)
val mkdir_p_sync : ?perm:int -> string -> unit

(** A read-only descriptor on [path], unlinked before this returns: the caller
    gets the bytes without the name, and nothing is left behind if it dies
    holding them. *)
val open_and_unlink : string -> Unix.file_descr

(** Whether [pid] names a running process. A pid reused since it was recorded
    reads as alive. *)
val pid_alive : int -> bool

(** Capacity of a filesystem, in bytes. [avail] is what an unprivileged writer
    can still use; [free] also counts the margin reserved for root, and is the
    one a used-space figure must be derived from. *)
type disk_space = { avail : int64; free : int64; total : int64 }

(** [disk_space path] is the capacity of the filesystem holding [path], or
    [None] when [path] cannot be stat'd. One syscall: cheap enough to call per
    status request. *)
val disk_space : string -> disk_space option

(** What a platform owes beyond {!Retry.SYSCALLS}: whole files, a directory's
    names, and bigstrings on a descriptor. Everything {!Make} adds is built from
    these. *)
module type PRIMITIVES = sig
  type 'a io
  type fd

  (** [None] for any failure, a missing path included. *)
  val read_file_opt : string -> string option io

  val write_file : string -> string -> unit io

  (** Without ["."] and [".."]. *)
  val readdir_list : string -> string list io

  (** At the descriptor's own position, which they advance. *)
  val bread : fd -> Bigstringaf.t -> int -> int -> int io

  val bwrite : fd -> Bigstringaf.t -> int -> int -> int io

  (** The offset travels with the call and the descriptor's own position is
      untouched, so ranges of one file may be moved concurrently through one
      descriptor.

      These need not yield, and under Lwt they do not. *)
  val pread : fd -> Bigstringaf.t -> file_offset:int -> int -> int -> int io

  val pwrite : fd -> Bigstringaf.t -> file_offset:int -> int -> int -> int io
end

module Make
    (Io : Io.S)
    (Sys : Retry.SYSCALLS with type 'a io := 'a Io.t)
    (P : PRIMITIVES with type 'a io := 'a Io.t and type fd := Sys.fd) : sig
  (** Bytes outside the OCaml heap. Spelled as {!Bigstringaf.t} rather than the
      Bigarray type it abbreviates so that its fast blits and comparisons are
      available wherever a buffer is; the two are the same type, and FUSE's own
      buffers are passed straight in as one. *)
  type buffer = Bigstringaf.t

  (** Zero [len] bytes of [buf] from [pos]: a hole a read did not cover. *)
  val zero : buffer -> pos:int -> len:int -> unit

  (** Move as much of [buf] as the file holds, from [offset], through a
      descriptor opened and closed for the call. Answers what was moved. *)
  val read : string -> buffer -> offset:int64 -> int Io.t

  val write : string -> buffer -> offset:int64 -> int Io.t

  (** [pread Sys.fd buf ~file_offset pos len] fills [len] bytes of [buf] from
      [pos], reading [Sys.fd] at [file_offset]. The offset travels with the
      call, so several ranges of one file can be moved concurrently through one
      descriptor. *)
  val pread : Sys.fd -> buffer -> file_offset:int -> int -> int -> int Io.t

  val pwrite : Sys.fd -> buffer -> file_offset:int -> int -> int -> int Io.t

  (** Create [path] and any missing parents (mode 0o755); tolerant of races. *)
  val mkdir_p : string -> unit Io.t

  (** {!mkdir_p} on the parent directory of [path]. *)
  val ensure_parent : string -> unit Io.t

  (** [atomic_write path data] writes [data] to a uniquely named temp file in
      [path]'s directory, then renames it over [path]. Safe against concurrent
      writers of the same path, in this process or another. *)
  val atomic_write : string -> string -> unit Io.t

  (** {!atomic_write} for a body assembled from pieces, each known by position.
      [atomic_write_at path ~size f] sizes the temp file to [size] up front — so
      a full disk fails before the pieces are produced — then calls [f put],
      where [put ~offset data] writes one range. Writes go through {!pwrite} and
      carry their own offset, so pieces may be produced and written concurrently
      and out of order, and a large body is never held whole in memory. The
      rename happens only once [f] returns, so a reader never sees a partial
      body. Every byte of [size] must be covered exactly once. *)
  val atomic_write_at :
    string ->
    size:int ->
    ((offset:int -> buffer -> unit Io.t) -> unit Io.t) ->
    unit Io.t

  (** [copy_file ~src ~dst] copies [src] over [dst], creating or truncating it.
  *)
  val copy_file : src:string -> dst:string -> unit Io.t

  (** The whole file as a string, [None] if it cannot be read. *)
  val read_file_opt : string -> string option Io.t

  (** Directory entries of [path], excluding ["."] and [".."]. *)
  val readdir_list : string -> string list Io.t

  (** {!readdir_list}, answering [[]] for a directory that is missing or cannot
      be read. For a caller sweeping a layout, where an absent directory and an
      empty one mean the same thing. Only [Unix_error] is swallowed. *)
  val readdir_list_quiet : string -> string list Io.t

  (** [true] if [path] exists and is a directory (following symlinks). *)
  val is_directory : string -> bool Io.t

  (** [stat] as an option: [None] for a path that is absent or cannot be stat'd
      for any other reason. *)
  val stat_opt : string -> Unix.stats option Io.t

  val stat_opt_large : string -> Unix.LargeFile.stats option Io.t

  (** lstat-based classifier. Returns [`Dir], [`File size], [`Symlink target],
      or [`Missing] on any error (dangling link, ENOENT, EACCES, …). A symlink's
      own size is its target's length and is read with the target instead. *)
  val lstat_kind :
    string -> [ `Dir | `File of int64 | `Symlink of string | `Missing ] Io.t

  (** Recursively delete [path]; missing paths and unlink/rmdir errors are
      ignored. Symlinks are removed, not followed. *)
  val rm_rf : string -> unit Io.t

  (** Delete [path], ignoring a missing file or any other [Unix_error]. *)
  val unlink_quiet : string -> unit Io.t

  (** [reap_older_than ~cutoff dir] deletes every file under [dir] whose mtime
      predates [cutoff] and prunes directories left empty, returning [true] when
      [dir] holds nothing afterwards. Best-effort; a missing [dir] reads as
      empty. *)
  val reap_older_than : cutoff:float -> string -> bool Io.t
end
