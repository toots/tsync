(** File content as bytes, read per chunk out of {!Chunk_cache}.

    A file is never assembled: a read maps its byte range onto the chunks
    backing it, fetching only the ones that are absent. No per-file state is
    kept beyond a read-ahead hint, and none is written to disk. *)

module Make (C : Conf.S) (R : Remote.S) : sig
  (** Fills [buf] from [offset] in the file [manifest] describes, returning the
      byte count — short only at end of file. [id] is for the read-ahead
      heuristic alone. Raises {!Backend.Backend_error} for a manifest whose
      chunk list has a hole, rather than serving zeros as content. *)
  val pread :
    id:string ->
    manifest:Manifest.t ->
    Local_io.buffer ->
    offset:int64 ->
    int Lwt.t

  (** [key]'s published manifest: the local sidecar when there is one, else the
      backend's — so a file that was never cached still reports its real logical
      size and mtime rather than the manifest object's byte size. *)
  val resolved_manifest : string -> Manifest.t option Lwt.t

  (** {!pread} for a key of this domain, resolved through
      {!Manifest.Make.resolve}: staged edits, else what was published, else the
      backend's manifest. *)
  val pread_key : string -> Local_io.buffer -> offset:int64 -> int Lwt.t

  (** {2 Writes}

      Bytes reach disk before the staged manifest that references them, so a
      crash leaves at worst an unreferenced staged body — never a manifest
      pointing at bytes that were never written. *)

  (** Write [buf] at [offset], growing the file as needed. Returns the byte
      count. A write covering only part of an inherited chunk copies that chunk
      into a staged body first: content-addressed chunks are immutable. *)
  val write : string -> Local_io.buffer -> offset:int64 -> int Lwt.t

  (** Resize: drop whole chunks past the end and resize the boundary chunk. A
      grow is pure metadata — the new chunks are holes reading as zeros. *)
  val truncate : string -> int64 -> unit Lwt.t

  (** Reset [key] to an empty staged file, dropping any staged bodies. *)
  val create : string -> unit Lwt.t

  (** Upload [key]'s staged edits and promote them: staged bodies are renamed
      under the content keys they hashed to, the sidecar becomes what was
      published, and the staged manifest goes. No-op when nothing is staged.

      The upload records what it published in the staged manifest before
      touching anything else, so a crash before that point re-uploads identical
      bytes and one after replays only local moves. Every later step is
      idempotent. *)
  val sync : string -> ?cancel:bool ref -> unit -> unit Lwt.t

  (** {2 Chunk store housekeeping}

      Routed through here so a domain has exactly one chunk store instance: two
      would each keep their own in-flight table and stop deduplicating each
      other's downloads. *)

  (** Delete chunk bodies, oldest first, while the store is over [C.max_cache].
      Never touches staged bodies. *)
  val enforce_chunk_cap : unit -> unit Lwt.t

  (** [(chunks, bytes)] held locally. *)
  val chunk_stats : unit -> (int * int) Lwt.t

  val downloads_in_flight : unit -> int

  (** Whole files pulled in since start-up, by any route. *)
  val downloads_completed_count : unit -> int

  (** Stage a whole file handed over by a frontend as [key]'s new content,
      replacing anything staged before it. *)
  val stage_whole : string -> src_path:string -> unit Lwt.t

  (** [(chunks present locally, chunks total)] for [key]; [(0, 0)] when it has
      no manifest at all. Staged bodies count as present. *)
  val chunk_residency : string -> (int * int) Lwt.t

  (** Fetch every chunk [key] needs, so reads are served locally afterwards.
      Writes the sidecar first for a file that has no local metadata yet. *)
  val ensure_local : string -> unit Lwt.t

  (** Write [key]'s whole content to [dst_path] (mtime included) through the
      normal read path — for a caller that needs a real file: an export, or the
      copy handed to a frontend. *)
  val assemble_to : string -> dst_path:string -> unit Lwt.t

  (** Writes that range of [key] into [dst_path] at the same offset, leaving the
      rest sparse, and returns the byte count — short only at end of file. Only
      the chunks the range covers are fetched, so a large file is served a piece
      at a time. [dst_path] is created even for a range past the end. *)
  val fetch_range :
    string -> dst_path:string -> offset:int -> length:int -> int Lwt.t

  (** [Some (bytes_done, bytes_total)] while [key] is being pulled in whole;
      [None] otherwise. *)
  val download_progress : string -> (int * int) option

  (** Drop [key]'s cached chunks; they re-fetch on demand. Unreference-blind: a
      chunk shared with another file goes too. Staged bodies are untouched. *)
  val forget_chunks : string -> unit Lwt.t

  (** Drop [key]'s staged manifest and the bodies it names. *)
  val discard_staged : string -> unit Lwt.t

  (** Where a whole staged body sits on disk, for a reader that wants the bytes
      an upload is sending. [None] once chunked, or for an unstaged key. *)
  val staged_body_path : string -> string option Lwt.t

  (** Delete staged bodies no staged manifest names, and prune the empty
      directories left in the staged manifest tree. Startup only: staging
      creates a body before the manifest that names it. *)
  val reclaim_staged_orphans : unit -> unit Lwt.t
end
