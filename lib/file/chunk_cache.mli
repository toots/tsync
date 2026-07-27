(** The local cache-chunk store: {!Chunk_group} bodies named by their content
    key.

    A group is present iff its file exists — there is no residency record — and
    any group may vanish at any time (the cache cap deletes them), so every read
    treats a miss as ordinary and fetches again. Bodies are shared: two files
    whose chunks group identically are one file on disk and one download. *)

(** What the store needs from the backend layer. {!Remote.S} satisfies it.
    Grouping is invisible here: a cache chunk is fetched as its members. *)
module type Fetch = sig
  val get_chunk : chunk_key:string -> string Lwt.t
end

module Make (C : Conf.S) (F : Fetch) : sig
  (** Whether this group's body is local. *)
  val exists : Chunk_group.t -> bool Lwt.t

  (** Put the body on disk unless already there, atomically. Concurrent callers
      for one group await a single fetch. [force:true] re-fetches regardless,
      for a body believed corrupt. *)
  val ensure : ?force:bool -> group:Chunk_group.t -> unit -> unit Lwt.t

  (** Write a group from bytes the caller already holds, one member at a time —
      the tail of a promotion, where every member is a local staged body. No-op
      when the body is already here. *)
  val put_group :
    group:Chunk_group.t -> member:(int -> string Lwt.t) -> unit Lwt.t

  (** Fill [buf] from stored chunk [index], starting [chunk_off] bytes into that
      chunk and fetching the group if absent. A body that vanishes (or is
      truncated) under the read is fetched again and the read retried once. *)
  val read_into :
    group:Chunk_group.t ->
    index:int ->
    Local_io.buffer ->
    chunk_off:int ->
    int Lwt.t

  (** One stored chunk's bytes if its group is already here, without fetching.
  *)
  val member_if_local : group:Chunk_group.t -> index:int -> string option Lwt.t

  (** Drop one group body. It is re-fetched on the next read. *)
  val forget : group:Chunk_group.t -> unit Lwt.t

  (** Re-hash every member segment of a group already on disk against the key it
      was published under, deleting the body when one does not match. [true] if
      the group survived (or was not here to begin with). Driven from
      {!Recheck}, which supplies the groups: unlike a lone chunk, a group body
      cannot be checked against its own name. *)
  val verify_group : group:Chunk_group.t -> bool Lwt.t

  (** {2 Staged bodies}

      A chunk being written locally has no content key yet — its bytes are still
      changing — so it lives under a uuid until the upload that hashes it
      publishes, and the group it belongs to is written out whole
      ({!put_group}). Staged bodies are unsynced data and are never reclaimed by
      the cap. One body per *stored* chunk: that is what an upload sends. *)

  (** Path of a staged body, for the upload that reads and hashes it. *)
  val staged_path : string -> string

  (** Create a sparse body of [len] zero bytes. *)
  val stage_empty : uuid:string -> len:int -> unit Lwt.t

  (** Create a body holding a published chunk's bytes, read out of its group,
      for a write that does not replace all of them (read-modify-write). *)
  val stage_from_chunk :
    group:Chunk_group.t -> index:int -> uuid:string -> unit Lwt.t

  val stage_write : uuid:string -> Local_io.buffer -> chunk_off:int -> int Lwt.t

  val stage_read_into :
    uuid:string -> Local_io.buffer -> chunk_off:int -> int Lwt.t

  val stage_truncate : uuid:string -> len:int -> unit Lwt.t
  val stage_forget : uuid:string -> unit Lwt.t

  (** {2 Whole bodies}

      A frontend that hands back a complete file gets it adopted as one file: no
      chunk split, and a rename rather than a copy when it is already on this
      filesystem. *)

  val whole_path : string -> string

  (** Take over [src] as whole body [uuid] (rename, or copy across filesystems).
  *)
  val adopt_whole : src:string -> uuid:string -> unit Lwt.t

  val whole_read_into :
    uuid:string -> Local_io.buffer -> offset:int64 -> int Lwt.t

  val whole_forget : uuid:string -> unit Lwt.t

  (** Number of downloads currently in flight. *)
  val in_flight : unit -> int

  (** [(cache chunks, bytes)] currently held. *)
  val stats : unit -> (int * int) Lwt.t

  (** While the store exceeds [C.max_cache], delete cache-chunk bodies
      oldest-mtime first. No-op when [max_cache] is unset. Needs no notion of
      what is in use: a body deleted from under a reader is fetched again. Never
      touches staged data, which lives in a different tree. *)
  val enforce_cap : unit -> unit Lwt.t
end
