type buffer = Local_io.buffer

module type S = sig
  type t = string

  val manifest_path : t -> string
  val rel_key : t -> string
  val read_manifest : t -> Manifest.t option Lwt.t

  (** Like {!read_manifest}, but falls back to fetching and parsing the backend
      manifest when there is no local sidecar, so a backend-only file resolves
      to its real logical size/mtime instead of the manifest object's byte size.
  *)
  val resolved_manifest : t -> Manifest.t option Lwt.t

  val write_manifest : t -> Manifest.t -> unit Lwt.t
  val upload : ?cancel:bool ref -> t -> unit Lwt.t

  (** Fetch every chunk [t] needs, so later reads are served locally. Produces
      no file: a caller that wants one asks for it by name with {!assemble_to}.
      Idempotent, and concurrent calls for one key share the fetching. *)
  val ensure_cached : t -> unit Lwt.t

  (** Write [t]'s whole content to [dst_path], fetching whatever it still needs.
      For a frontend that must hand over a real file and takes it over; the
      daemon keeps no other copy, the content lives in the chunk store.

      The caller names the path rather than being handed one, because the place
      a file may live is the caller's constraint: the macOS File Provider must
      give the system a file in a directory of the system's choosing, and is not
      permitted to move one in from elsewhere afterwards. *)
  val assemble_to : t -> dst_path:string -> unit Lwt.t

  (** [fetch_range t ~dst_path ~offset ~length] is {!assemble_to} for one range:
      it writes those bytes into [dst_path] at the same offset and leaves the
      rest of the file sparse, returning the byte count — short only at end of
      file. Only the chunks the range covers are fetched, which is how a large
      file is opened without materializing it whole. [dst_path] is created even
      when the range lies past the end. *)
  val fetch_range :
    t -> dst_path:string -> offset:int -> length:int -> int Lwt.t

  val stat : t -> Unix.LargeFile.stats option Lwt.t

  (** Return the symlink target for a key whose manifest is a symlink, or [None]
      if the key is absent or is a regular file. *)
  val readlink : t -> string option Lwt.t

  (** Directory listing served from the local manifest mirror: files (with real
      keys derived from each manifest's [path]) and subdirectory names (mtime
      unavailable locally, hence [None]). *)
  val list_children :
    prefix:string ->
    (Backend.file_entry list * (string * float option) list) Lwt.t

  (** Recursive file listing under [prefix], served from the local mirror. *)
  val list_tree : prefix:string -> Backend.file_entry list Lwt.t

  (** A handle closed: queue the file for upload if it has staged edits. Nothing
      else is decided here — the staged manifest, not an open count, records
      what is owed, and it survives a restart. *)
  val close : t -> unit Lwt.t

  (** Finish every upload the staged tree still owes — the crash-recovery entry
      point, run once at startup. *)
  val recover_staged : unit -> unit Lwt.t

  (** Keep the chunk store under [C.max_cache]; never touches staged data. *)
  val enforce_chunk_cap : unit -> unit Lwt.t

  (** [(chunks, bytes)] held in the chunk store. *)
  val chunk_stats : unit -> (int * int) Lwt.t

  (** [t]'s content: staged edits if any, else what was published. *)
  val resolve :
    t ->
    [ `Staged of Manifest.staged * Manifest.t option | `Published of Manifest.t ]
    option
    Lwt.t

  (** [(chunks present locally, chunks total)] for [t]. *)
  val chunk_residency : t -> (int * int) Lwt.t

  (** Chunk downloads currently in flight. *)
  val downloads_in_flight : unit -> int

  (** Files with unsynced local edits, i.e. owing an upload. *)
  val staged_count : unit -> int Lwt.t

  (** Whole-file materializations completed since the daemon started. *)
  val downloads_completed_count : unit -> int

  (** Files written but not yet published, as this process currently tracks them
      — the in-memory view of what {!staged_count} finds on disk, and free to
      read. *)

  (** Whether the metadata lock is held, and whether anything is queued behind
      it. A mount that has stopped answering while its backend looks fine is
      usually this: held, with waiters. *)
  val meta_locked : unit -> bool

  val meta_waiters : unit -> bool

  (** [Some (bytes_done, total_bytes)] while [key] is being pulled in whole;
      [None] when idle. *)
  val download_progress : t -> (int * int) option

  (** Drop [t]'s cached chunks, keeping its manifest: the file stays listed and
      re-fetches on demand. Unreference-blind, and staged bodies are untouched.
  *)
  val evict : t -> unit Lwt.t

  val create : t -> unit Lwt.t

  (** Stage a whole file handed over by a frontend as [t]'s new content. *)
  val write_whole : t -> src_path:string -> unit Lwt.t

  val read : t -> buffer -> offset:int64 -> int Lwt.t
  val write : t -> buffer -> offset:int64 -> int Lwt.t
  val cancel_upload : t -> bool
  val truncate : t -> int64 -> unit Lwt.t
  val apply_delete : t -> unit Lwt.t
  val queue_put : t -> unit Lwt.t
  val delete : t -> unit Lwt.t
  val mkdir : t -> unit Lwt.t
  val rmdir : t -> unit Lwt.t
  val rename : src:t -> dst:t -> unit Lwt.t
  val revert : ?version:string -> t -> unit Lwt.t
  val symlink : target:string -> t -> unit Lwt.t
  val apply_foreign_ops : Journal.op list -> unit Lwt.t
end

module Make_with_layout (C : Conf.S) (Sq : Sync_queue.S) (L : Layout.S) : S
module Make (C : Conf.S) (Sq : Sync_queue.S) : S
