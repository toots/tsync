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
    key:string ->
    src_path:string ->
    mtime:float ->
    chunk_size:int ->
    ?cancel:bool ref ->
    ?on_progress:(bytes:int -> sent:bool -> unit) ->
    unit ->
    Manifest.t Lwt.t

  (** Fetch one chunk body from the domain's stores by its content key
      ([Manifest.chunk_key], without the domain's chunk prefix). *)
  val get_chunk : chunk_key:string -> Chunk.t Lwt.t

  (** Chunk size for files this client creates: [Conf.S.chunk_size] when the
      config says, else what the domain's stores recommend — an http-proxy
      answers with the serving domain's own, so the setting need not be mirrored
      in two configs — else [Conf.default_chunk_size]. Existing files always use
      the size recorded in their own manifest and never come near this. *)
  val chunk_size : unit -> int Lwt.t

  (** Chunk keys this session has seen present on the stores. Bounded, so it
      counts what the memo holds rather than what the session has uploaded;
      exposed because that bound is invisible from {!upload}, which behaves the
      same either way. *)
  val known_chunk_count : unit -> int

  (** Upload a file whose bytes the caller supplies per chunk, then publish its
      manifest. [source index] is either [`Reuse key] — an unchanged chunk,
      neither read nor sent, kept under the key it already has — or [`Fill f],
      where [f buf] writes the chunk's bytes into the first [Manifest.chunk_len]
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
    key:string ->
    size:int64 ->
    chunk_size:int ->
    mtime:float ->
    source:
      (int ->
      [ `Reuse of string | `Fill of Local_io.buffer -> unit Lwt.t ] Lwt.t) ->
    ?cancel:bool ref ->
    unit ->
    Manifest.t Lwt.t

  (** Fetch only the manifest for [key] from the primary backend. Returns [None]
      if the key does not exist or is not a manifest. *)
  val fetch_manifest : key:string -> unit -> Manifest.t option Lwt.t

  (** {!fetch_manifest} saying which nothing it found. Only [`Absent] is an
      answer about the domain: [`Unresolved] is this client not knowing the
      key's folder yet, and [`Unreadable] a body caught mid-write. A caller that
      remembers an answer may remember the first and must not remember the
      other two, which change with nothing about the domain changing. *)
  val fetch_manifest_state :
    key:string ->
    unit ->
    [ `Found of Manifest.t | `Absent | `Unresolved | `Unreadable ] Lwt.t
end

(** Keys are mapped to backend keys through [L]. Callers holding real paths want
    {!Make}; {!Layout.Identity} serves callers that already hold backend keys.
*)
module Make_with_layout (C : Conf.S) (L : Layout.S) : S

module Make (C : Conf.S) : S
