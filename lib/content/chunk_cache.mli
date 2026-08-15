(** The local cache-chunk store: {!Chunk_group} bodies named by their content
    key.

    A group is present iff its file exists, and any group may vanish at any time
    (the cache cap deletes them), so every read treats a miss as ordinary and
    fetches again.

    Bodies are shared: two files whose chunks group identically are one file on
    disk and one download. *)

(** What the store needs from the backend layer. {!Remote.S} satisfies it.
    Grouping is invisible here: a cache chunk is fetched as its members. *)
module type Fetch = sig
  val get_chunk : chunk_key:string -> Chunk.t Lwt.t
end

module Make (C : Conf.S) (F : Fetch) : sig
  (** Whether this group's body is local. *)
  val exists : Chunk_group.t -> bool Lwt.t

  (** Put the body on disk unless already there, atomically. Concurrent callers
      for one group await a single fetch. [force:true] re-fetches regardless,
      for a body believed corrupt. *)
  val ensure : ?force:bool -> group:Chunk_group.t -> unit -> unit Lwt.t

  (** {!ensure}, answering whether the body had to come from a backend. A caller
      joining an in-flight fetch gets [true] as well: it waited on the network
      just as the caller that started the fetch did. *)
  val ensure_fetched : ?force:bool -> group:Chunk_group.t -> unit -> bool Lwt.t

  (** What a read cost. [from_backend] is the part a caller cannot work out for
      itself, and is what attributes a network wait to the file being read. *)
  type served = { bytes : int; from_backend : bool }

  (** Write a group from bytes the caller already holds, one member at a time —
      the tail of a promotion, where every member is a local staged body. No-op
      when the body is already here. *)
  val put_group :
    group:Chunk_group.t -> member:(int -> Chunk.t Lwt.t) -> unit Lwt.t

  (** Fill [buf] from stored chunk [index], starting [chunk_off] bytes into that
      chunk and fetching the group if absent. A body that vanishes (or is
      truncated) under the read is fetched again and the read retried once. *)
  val read_into :
    group:Chunk_group.t ->
    index:int ->
    Local_io.buffer ->
    chunk_off:int ->
    served Lwt.t

  (** Drop one group body. It is re-fetched on the next read. *)
  val forget : group:Chunk_group.t -> unit Lwt.t

  (** {2 Staged bodies}

      A chunk being written has no content key yet, its bytes still changing, so
      it lives under a uuid until the upload that hashes it publishes.

      One body holds a whole {!Chunk_group}, laid out as the group will be, so
      publishing it is {!stage_link_group} rather than a copy. Its members are
      told apart by the offset each slot carries.

      Staged bodies are unsynced data and are never reclaimed by the cap. *)

  (** Path of a staged body, for the upload that reads and hashes it. *)
  val staged_path : string -> string

  (** Create the body if absent and grow it to [len], never shrinking: one body
      holds a whole cache group, and a member written before its neighbours must
      not lose them. *)
  val stage_ensure : uuid:string -> len:int -> unit Lwt.t

  (** Set the length exactly. *)
  val stage_resize : uuid:string -> len:int -> unit Lwt.t

  val stage_write : uuid:string -> Local_io.buffer -> offset:int -> int Lwt.t

  val stage_read_into :
    uuid:string -> Local_io.buffer -> offset:int -> int Lwt.t

  (** Copy a published chunk's bytes out of its group into [offset] of a staged
      body, for a write that does not replace all of them. *)
  val stage_copy_chunk :
    group:Chunk_group.t -> index:int -> uuid:string -> offset:int -> unit Lwt.t

  (** Move [len] bytes between staged bodies, for regrouping. *)
  val stage_copy :
    src:string ->
    src_off:int ->
    dst:string ->
    dst_off:int ->
    len:int ->
    unit Lwt.t

  val stage_forget : uuid:string -> unit Lwt.t

  (** Publish a staged body under its group's content name, by giving the same
      bytes a second name rather than copying them. Both names are readable
      until the staged one is dropped, so a reader resolving either during a
      promotion finds it.

      [false] where the cache root cannot hold a second name for one inode, and
      the caller writes the group out instead. Whether it can is asked once.

      [len] is the caller's account of how long the body should be, and it must
      match the group's own or the two disagree about the layout and nothing is
      published. The body is resized to it first, which supplies zeros for a
      member never written and cuts anything past the last one. *)
  val stage_link_group :
    uuid:string -> len:int -> group:Chunk_group.t -> bool Lwt.t

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

  (** Number of downloads currently in flight. *)
  val in_flight : unit -> int

  (** [(cache chunks, bytes)] currently held. *)
  val stats : unit -> (int * int) Lwt.t

  (** While the store exceeds [C.max_cache], delete cache-chunk bodies
      oldest-mtime first; no-op when [max_cache] is unset.

      Needs no notion of what is in use, a body deleted under a reader being
      fetched again, and never touches staged data. *)
  val enforce_cap : unit -> unit Lwt.t
end
