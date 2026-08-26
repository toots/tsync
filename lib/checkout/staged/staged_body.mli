(** This client's unpublished bytes: the staged bodies a write lands in, and the
    whole files a frontend hands over entire.

    The only copy there is until an upload publishes them. Nothing here is
    re-fetchable, so nothing here is reclaimable — which is why it is a separate
    store from {!Chunk_cache} rather than a region of it the cap is told to
    spare.

    A chunk being written has no content key yet, its bytes still changing, so
    it lives under a uuid. One body holds a whole {!Manifest.Group}, laid out as
    the group will be, so publishing it is {!Make.link_group} rather than a
    copy. Its members are told apart by the offset each slot carries. *)

(** What this needs of a filesystem and of the retrying syscalls. *)
module type FS = sig
  type 'a io

  val copy_file : src:string -> dst:string -> unit io
  val ensure_parent : string -> unit io
  val unlink_quiet : string -> unit io
  val read : string -> Bigstring.t -> offset:int64 -> int io
  val write : string -> Bigstring.t -> offset:int64 -> int io
end

module type SYSCALLS = sig
  type 'a io
  type fd

  val openfile : string -> Unix.open_flag list -> Unix.file_perm -> fd io
  val close : fd -> unit io
  val rename : string -> string -> unit io

  module LargeFile : sig
    val stat : string -> Unix.LargeFile.stats io
    val ftruncate : fd -> int64 -> unit io
  end
end

module Over
    (Io : Io.S)
    (_ : FS with type 'a io := 'a Io.t)
    (_ : SYSCALLS with type 'a io := 'a Io.t) : sig
  (** What the staged half needs of the cache: read a published chunk it is
      overwriting part of, and take a finished body to publish. *)
  module type Cache = sig
    val read_into :
      group:Manifest.Group.t ->
      index:int ->
      Bigstring.t ->
      chunk_off:int ->
      Chunk_cache.served Io.t

    val link_in : src:string -> group:Manifest.Group.t -> bool Io.t
  end

  module Make (C : Conf.S) (Cache : Cache) : sig
    (** Path of a staged body, for the upload that reads and hashes it. *)
    val path : string -> string

    (** Create the body if absent and grow it to [len], never shrinking: one
        body holds a whole cache group, and a member written before its
        neighbours must not lose them. *)
    val ensure : uuid:string -> len:int -> unit Io.t

    (** Set the length exactly. *)
    val resize : uuid:string -> len:int -> unit Io.t

    val write : uuid:string -> Bigstring.t -> offset:int -> int Io.t
    val read_into : uuid:string -> Bigstring.t -> offset:int -> int Io.t

    (** Copy a published chunk's bytes out of its group into [offset] of a
        staged body, for a write that does not replace all of them. *)
    val copy_chunk :
      group:Manifest.Group.t ->
      index:int ->
      uuid:string ->
      offset:int ->
      unit Io.t

    (** Move [len] bytes between staged bodies, for regrouping. *)
    val copy :
      src:string ->
      src_off:int ->
      dst:string ->
      dst_off:int ->
      len:int ->
      unit Io.t

    val forget : uuid:string -> unit Io.t

    (** Publish a staged body under its group's content name, via
        {!Chunk_cache.link_in}.

        [false] where the cache root cannot hold a second name for one inode,
        and the caller writes the group out instead.

        [len] is the caller's account of how long the body should be, and it
        must match the group's own or the two disagree about the layout and
        nothing is published. The body is resized to it first, which supplies
        zeros for a member never written and cuts anything past the last one. *)
    val link_group :
      uuid:string -> len:int -> group:Manifest.Group.t -> bool Io.t

    (** {2 Whole bodies}

        A frontend that hands back a complete file gets it adopted as one file:
        no chunk split, and a rename rather than a copy when it is already on
        this filesystem. *)

    val whole_path : string -> string

    (** Take over [src] as whole body [uuid]: a rename, or a copy across
        filesystems. *)
    val adopt_whole : src:string -> uuid:string -> unit Io.t

    val whole_read_into : uuid:string -> Bigstring.t -> offset:int64 -> int Io.t
    val whole_forget : uuid:string -> unit Io.t
  end
end
