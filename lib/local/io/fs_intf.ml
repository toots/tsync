module type S = sig
  type 'a io
  type fd

  (** Bytes outside the OCaml heap. Spelled as {!Bigstringaf.t} rather than the
      Bigarray type it abbreviates so that its fast blits and comparisons are
      available wherever a buffer is; the two are the same type, and FUSE's own
      buffers are passed straight in as one. *)
  type buffer = Bigstringaf.t

  (** Zero [len] bytes of [buf] from [pos]: a hole a read did not cover. *)
  val zero : buffer -> pos:int -> len:int -> unit

  (** Move as much of [buf] as the file holds, from [offset], through a
      descriptor opened and closed for the call. Answers what was moved. *)
  val read : string -> buffer -> offset:int64 -> int io

  val write : string -> buffer -> offset:int64 -> int io

  (** [pread fd buf ~file_offset pos len] fills [len] bytes of [buf] from [pos],
      reading [fd] at [file_offset]. The offset travels with the call, so
      several ranges of one file can be moved concurrently through one
      descriptor. *)
  val pread : fd -> buffer -> file_offset:int -> int -> int -> int io

  val pwrite : fd -> buffer -> file_offset:int -> int -> int -> int io

  (** Create [path] and any missing parents (mode 0o755); tolerant of races. *)
  val mkdir_p : string -> unit io

  (** {!mkdir_p} on the parent directory of [path]. *)
  val ensure_parent : string -> unit io

  (** [atomic_write path data] writes [data] to a uniquely named temp file in
      [path]'s directory, then renames it over [path]. Safe against concurrent
      writers of the same path, in this process or another. *)
  val atomic_write : string -> string -> unit io

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
    ((offset:int -> buffer -> unit io) -> unit io) ->
    unit io

  (** [copy_file ~src ~dst] copies [src] over [dst], creating or truncating it.
  *)
  val copy_file : src:string -> dst:string -> unit io

  (** The whole file as a string, [None] if it cannot be read. *)
  val read_file_opt : string -> string option io

  (** Directory entries of [path], excluding ["."] and [".."]. *)
  val readdir_list : string -> string list io

  (** {!readdir_list}, answering [[]] for a directory that is missing or cannot
      be read. For a caller sweeping a layout, where an absent directory and an
      empty one mean the same thing. Only [Unix_error] is swallowed. *)
  val readdir_list_quiet : string -> string list io

  (** [true] if [path] exists and is a directory (following symlinks). *)
  val is_directory : string -> bool io

  (** [stat] as an option: [None] for a path that is absent or cannot be stat'd
      for any other reason. *)
  val stat_opt : string -> Unix.stats option io

  val stat_opt_large : string -> Unix.LargeFile.stats option io

  (** lstat-based classifier. Returns [`Dir], [`File size], [`Symlink target],
      or [`Missing] on any error (dangling link, ENOENT, EACCES, …). A symlink's
      own size is its target's length and is read with the target instead. *)
  val lstat_kind :
    string -> [ `Dir | `File of int64 | `Symlink of string | `Missing ] io

  (** Recursively delete [path]; missing paths and unlink/rmdir errors are
      ignored. Symlinks are removed, not followed. *)
  val rm_rf : string -> unit io

  (** Delete [path], ignoring a missing file or any other [Unix_error]. *)
  val unlink_quiet : string -> unit io

  (** [reap_older_than ~cutoff dir] deletes every file under [dir] whose mtime
      predates [cutoff] and prunes directories left empty, returning [true] when
      [dir] holds nothing afterwards. Best-effort; a missing [dir] reads as
      empty. *)
  val reap_older_than : cutoff:float -> string -> bool io
end
