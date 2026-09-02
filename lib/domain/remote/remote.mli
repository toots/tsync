exception Cancelled

(** The file an upload was reading changed under it, so nothing is published:
    its chunks would otherwise describe bytes the file never held together. The
    caller re-imports to pick up what it now holds. *)
exception Source_changed of string

(** Cap on the per-session memo of chunk keys known present. Reaching it clears
    the memo, which costs a HEAD per chunk again. Settable so a test can reach
    it without uploading a terabyte. *)
val set_max_known : int -> unit

module type S = sig
  type 'a io

  (** Upload [src_path] as chunks under [key]: each chunk is read, hashed (chunk
      key) and uploaded if absent, then the manifest is written. For a file
      handed over whole — import, and the FileProvider's re-import. Setting
      [cancel] aborts at the next chunk boundary with {!Cancelled}, and a source
      that moves while it is being read raises {!Source_changed}.

      [on_progress] fires per chunk with that chunk's length, deduplicated
      chunks included: it says how much of the file is on the store, which is
      what a caller reporting a multi-hour upload wants, rather than how much
      crossed the wire. [sent] is false for a chunk the store already had, so a
      caller measuring throughput divides by what it actually transferred rather
      than by what it hashed.

      Chunks complete out of order, so only the running sum means anything, and
      it runs while the chunk holds its buffer slot, so it must return at once.
      {!upload_chunks} reports nothing. *)
  val upload :
    key:Logical_key.t ->
    src_path:string ->
    mtime:float ->
    chunk_size:int ->
    ?cancel:bool ref ->
    ?on_progress:(bytes:int -> sent:bool -> unit) ->
    unit ->
    Manifest.t io

  (** Fetch one chunk body from the domain's stores by its content key
      ([Manifest.chunk_key], without the domain's chunk prefix). *)
  val get_chunk : chunk_key:string -> Bigstring.t io

  (** [length] bytes of a stored chunk from [offset], for a reader that wants
      part of one. Bounded by the same reads-in-flight budget as {!get_chunk}, a
      range being a round trip like any other. *)
  val get_chunk_range :
    chunk_key:string -> offset:int -> length:int -> Bigstring.t io

  (** Whether reads of this domain's chunks are cheap enough that a reader
      wanting part of one is better served the whole thing — see
      {!Backend.S.fast_read}. *)
  val fast_read : bool

  (** Chunk size for files this client creates: [Conf.S.chunk_size] when the
      config says, else what the domain's stores recommend — an http-proxy
      answers with the serving domain's own, so the setting need not be mirrored
      in two configs — else [Conf.default_chunk_size]. Existing files always use
      the size recorded in their own manifest and never come near this. *)
  val chunk_size : unit -> int io

  (** Chunk keys this session has seen present on the stores. Bounded, so it
      counts what the memo holds rather than what the session has uploaded;
      exposed because that bound is invisible from {!upload}, which behaves the
      same either way. *)
  val known_chunk_count : unit -> int

  (** Upload a file whose bytes the caller supplies per chunk, then publish its
      manifest. [source index] is either [`Reuse key] — an unchanged chunk,
      neither read nor sent, kept under the key it already has — or [`Fill f],
      where [f buf] writes the chunk's bytes into the first [Chunks.length_of]
      of [buf]. An empty file still yields one empty chunk. [cancel] aborts at
      the next chunk boundary with {!Cancelled}, unpublishing the manifest if it
      already went.

      [buf] arrives uninitialised, so [f] writes every byte it claims and a
      short read pads rather than returning early.

      [source] itself does no I/O, deciding only which case a chunk is: one that
      reads up front puts the whole file in memory before anything queues for a
      buffer.

      {b A chunk a [`Reuse] names is taken on trust.} That branch carries a key
      and no bytes, so there is nothing to re-upload if the stored copy turns
      out to be corrupt, and unlike the [`Fill] path this never consults
      {!Corruption}. A marked chunk inherited by a staged partial write
      therefore stays marked and stays bad.

      Deliberate: the alternative is fetching a chunk the caller never asked
      for, on a path that must stay free of I/O to decide a case.
      [tsync data-integrity --repair] takes the bytes from another store, which
      has some to work with. *)
  val upload_chunks :
    key:Logical_key.t ->
    size:int64 ->
    chunk_size:int ->
    mtime:float ->
    source:(int -> unit io Chunk_source.t io) ->
    ?cancel:bool ref ->
    unit ->
    Manifest.t io

  (** Fetch only the manifest for [key] from the primary backend. Returns [None]
      if the key does not exist or is not a manifest. *)
  val fetch_manifest : key:Logical_key.t -> unit -> Manifest.t option io
end

(** The key scheme a caller holding real paths wants. *)
module type INODE_LAYOUT = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) :
    Layout.S with type 'a io := 'a io
end

(** Publishing a manifest and taking it back, which is all this does with one.
*)
module type MANIFESTS = sig
  type 'a io

  module Make
      (_ : Conf.S with type 'a io = 'a io)
      (_ : Layout.S with type 'a io := 'a io) : sig
    val put_manifest : key:Logical_key.t -> data:Bigstring.t -> unit io

    val get_manifest_state :
      key:Logical_key.t -> [ `Body of string | `Absent | `Unresolved ] io

    val delete_manifest : key:Logical_key.t -> unit io
  end
end

(** Snapshotting what a write is about to replace. *)
module type VERSIONS = sig
  type 'a io

  module Make
      (_ : Conf.S with type 'a io = 'a io)
      (_ : Layout.S with type 'a io := 'a io) : sig
    val save_version : key:Logical_key.t -> unit io
  end
end

(** Where a chunk is while a collection is under way, and what keeps one alive
    across it. *)
module type COLLECTION = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val get : string -> Bigstring.t io
    val get_range : string -> offset:int -> length:int -> Bigstring.t io
    val head : string -> Backend.file_entry option io
    val promote_all : count:int -> (int -> string) -> unit io
  end
end

(** Which chunks a store filed as not holding what their names say. *)
module type CORRUPTION = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val is_marked : string -> bool io
    val forget : string -> unit
  end
end

module Over
    (Io : Io.S)
    (_ : Bounded.S with type 'a io := 'a Io.t)
    (_ : Syscalls.S with type 'a io := 'a Io.t)
    (_ : INODE_LAYOUT with type 'a io := 'a Io.t)
    (_ : MANIFESTS with type 'a io := 'a Io.t)
    (_ : VERSIONS with type 'a io := 'a Io.t)
    (_ : COLLECTION with type 'a io := 'a Io.t)
    (_ : CORRUPTION with type 'a io := 'a Io.t) : sig
  (** Keys are mapped to backend keys through [L]. Callers holding real paths
      want {!Make}; {!Layout.Identity} serves callers that already hold backend
      keys. *)
  module Make_with_layout
      (_ : Conf.S with type 'a io = 'a Io.t)
      (_ : Layout.S with type 'a io := 'a Io.t) : S with type 'a io := 'a Io.t

  module Make (_ : Conf.S with type 'a io = 'a Io.t) :
    S with type 'a io := 'a Io.t
end
