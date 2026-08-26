(** The local cache-chunk store: {!Manifest.Group} bodies named by their content
    key.

    A group is present iff its file exists, and any group may vanish at any time
    (the cache cap deletes them), so every read treats a miss as ordinary and
    fetches again. That is the whole of what this store holds: everything here
    is re-fetchable, which is what lets {!Make.enforce_cap} delete by age alone.
    Unpublished bytes live in {!Staged_body}, out of its reach.

    Bodies are shared: two files whose chunks group identically are one file on
    disk and one download. *)

(** What this needs below it: a filesystem, the syscalls that retry past
    [EINTR], and pools to admit a few at a time. Each is a subset — what the
    cache calls and nothing else. *)
module type FS = sig
  type 'a io

  val ensure_parent : string -> unit io
  val readdir_list : string -> string list io
  val unlink_quiet : string -> unit io
  val read : string -> Bigstring.t -> offset:int64 -> int io

  val atomic_write_at :
    string ->
    size:int ->
    ((offset:int -> Bigstring.t -> unit io) -> unit io) ->
    unit io
end

module type SYSCALLS = sig
  type 'a io

  val file_exists : string -> bool io
  val stat : string -> Unix.stats io
  val link : string -> string -> unit io
  val utimes : string -> float -> float -> unit io
end

module type POOLS = sig
  type 'a io
  type t

  val create : ?max_waiting:int -> ?name:string -> max:int -> unit -> t
  val use : t -> (unit -> 'a io) -> 'a io
  val map_with : t -> ('a -> 'b io) -> 'a list -> 'b list io
  val filter_map_with : t -> ('a -> 'b option io) -> 'a list -> 'b list io
end

(** What the store needs from the backend layer. {!Remote.S} satisfies it.
    Grouping is invisible here: a cache chunk is fetched as its members. *)
module type Fetch = sig
  type 'a io

  val get_chunk : chunk_key:string -> Bigstring.t io
end

(** What a read cost. [from_backend] is the part a caller cannot work out for
    itself, and is what attributes a network wait to the file being read. *)
type served = { bytes : int; from_backend : bool }

module Make
    (Io : Io.S)
    (_ : FS with type 'a io := 'a Io.t)
    (_ : SYSCALLS with type 'a io := 'a Io.t)
    (_ : POOLS with type 'a io := 'a Io.t)
    (C : Conf.S)
    (F : Fetch with type 'a io := 'a Io.t) : sig
  (** Whether this group's body is local. *)
  val exists : Manifest.Group.t -> bool Io.t

  (** Put the body on disk unless already there, atomically. Concurrent callers
      for one group await a single fetch. [force:true] re-fetches regardless,
      for a body believed corrupt. *)
  val ensure : ?force:bool -> group:Manifest.Group.t -> unit -> unit Io.t

  (** {!ensure}, answering whether the body had to come from a backend. A caller
      joining an in-flight fetch gets [true] as well: it waited on the network
      just as the caller that started the fetch did. *)
  val ensure_fetched :
    ?force:bool -> group:Manifest.Group.t -> unit -> bool Io.t

  (** Write a group from bytes the caller already holds, one member at a time —
      the tail of a promotion, where every member is a local staged body. No-op
      when the body is already here. *)
  val put_group :
    group:Manifest.Group.t -> member:(int -> Bigstring.t Io.t) -> unit Io.t

  (** Fill [buf] from stored chunk [index], starting [chunk_off] bytes into that
      chunk and fetching the group if absent. A body that vanishes (or is
      truncated) under the read is fetched again and the read retried once. *)
  val read_into :
    group:Manifest.Group.t ->
    index:int ->
    Bigstring.t ->
    chunk_off:int ->
    served Io.t

  (** Adopt the file at [src] as this group's body, by giving those bytes a
      second name rather than copying them. Both names are readable until the
      caller drops its own, so a reader resolving either during a promotion
      finds it.

      [false] where the cache root cannot hold a second name for one inode, and
      the caller writes the group out instead. Whether it can is asked once.

      The caller owns [src] and must have sized it to the group's layout already
      — {!Staged.link_group} is that caller. *)
  val link_in : src:string -> group:Manifest.Group.t -> bool Io.t

  (** Drop one group body. It is re-fetched on the next read. *)
  val forget : group:Manifest.Group.t -> unit Io.t

  (** Number of downloads currently in flight. *)
  val in_flight : unit -> int

  (** [(cache chunks, bytes)] currently held. *)
  val stats : unit -> (int * int) Io.t

  (** While the store exceeds [C.max_cache], delete cache-chunk bodies
      oldest-mtime first; no-op when [max_cache] is unset.

      Needs no notion of what is in use, a body deleted under a reader being
      fetched again. *)
  val enforce_cap : unit -> unit Io.t
end
