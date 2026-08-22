(** This client's unpublished bytes: the staged bodies a write lands in, and the
    whole files a frontend hands over entire.

    The only copy there is until an upload publishes them. Nothing here is
    re-fetchable, so nothing here is reclaimable — which is why it is a separate
    store from {!Chunk_cache} rather than a region of it the cap is told to
    spare.

    A chunk being written has no content key yet, its bytes still changing, so
    it lives under a uuid. One body holds a whole {!Chunk_group}, laid out as
    the group will be, so publishing it is {!Make.link_group} rather than a
    copy. Its members are told apart by the offset each slot carries. *)

(** What the staged half needs of the cache: read a published chunk it is
    overwriting part of, and take a finished body to publish. *)
module type Cache = sig
  val read_into :
    group:Chunk_group.t ->
    index:int ->
    Local_io.buffer ->
    chunk_off:int ->
    Chunk_cache.served Lwt.t

  val link_in : src:string -> group:Chunk_group.t -> bool Lwt.t
end

module Make (C : Conf.S) (Cache : Cache) : sig
  (** Path of a staged body, for the upload that reads and hashes it. *)
  val path : string -> string

  (** Create the body if absent and grow it to [len], never shrinking: one body
      holds a whole cache group, and a member written before its neighbours must
      not lose them. *)
  val ensure : uuid:string -> len:int -> unit Lwt.t

  (** Set the length exactly. *)
  val resize : uuid:string -> len:int -> unit Lwt.t

  val write : uuid:string -> Local_io.buffer -> offset:int -> int Lwt.t
  val read_into : uuid:string -> Local_io.buffer -> offset:int -> int Lwt.t

  (** Copy a published chunk's bytes out of its group into [offset] of a staged
      body, for a write that does not replace all of them. *)
  val copy_chunk :
    group:Chunk_group.t -> index:int -> uuid:string -> offset:int -> unit Lwt.t

  (** Move [len] bytes between staged bodies, for regrouping. *)
  val copy :
    src:string ->
    src_off:int ->
    dst:string ->
    dst_off:int ->
    len:int ->
    unit Lwt.t

  val forget : uuid:string -> unit Lwt.t

  (** Publish a staged body under its group's content name, via
      {!Chunk_cache.link_in}.

      [false] where the cache root cannot hold a second name for one inode, and
      the caller writes the group out instead.

      [len] is the caller's account of how long the body should be, and it must
      match the group's own or the two disagree about the layout and nothing is
      published. The body is resized to it first, which supplies zeros for a
      member never written and cuts anything past the last one. *)
  val link_group : uuid:string -> len:int -> group:Chunk_group.t -> bool Lwt.t

  (** {2 Whole bodies}

      A frontend that hands back a complete file gets it adopted as one file: no
      chunk split, and a rename rather than a copy when it is already on this
      filesystem. *)

  val whole_path : string -> string

  (** Take over [src] as whole body [uuid]: a rename, or a copy across
      filesystems. *)
  val adopt_whole : src:string -> uuid:string -> unit Lwt.t

  val whole_read_into :
    uuid:string -> Local_io.buffer -> offset:int64 -> int Lwt.t

  val whole_forget : uuid:string -> unit Lwt.t
end
