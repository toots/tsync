(* What a frontend can do to a file in a domain, as a signature on its own.

   Both the upload queue's replay and the change poller are written against it,
   so neither depends on the implementation below it -- which is what lets a
   test drive them with a stub instead of a whole domain. No .mli: this module
   is already nothing but a signature. *)

type buffer = Local_io.buffer

(** A file the upload queue is working on right now. [rel] names it from the
    domain root, the way its reader sees it; [body] is where its bytes are on
    disk, for anything that wants to look at them. *)
type in_flight = { name : string; rel : string; body : string option }

module type S = sig
  type t = string

  val manifest_path : t -> string
  val rel_key : t -> string
  val read_manifest : t -> Manifest.t option Lwt.t

  (** {!read_manifest}, falling back to the backend manifest when there is no
      local sidecar, so a backend-only file resolves to its logical size and
      mtime rather than the manifest object's byte size. *)
  val resolved_manifest : t -> Manifest.t option Lwt.t

  val write_manifest : t -> Manifest.t -> unit Lwt.t
  val upload : ?cancel:bool ref -> t -> unit Lwt.t

  (** Fetch every chunk [t] needs, so later reads are served locally. Produces
      no file — see {!assemble_to}. Idempotent, and concurrent calls for one key
      share the fetching. *)
  val ensure_cached : t -> unit Lwt.t

  (** Write [t]'s whole content to [dst_path], fetching whatever it still needs.
      The daemon keeps no other copy; the content lives in the chunk store.

      The caller names the path because where a file may live is its constraint:
      the macOS File Provider must give the system a file in a directory of the
      system's choosing and may not move one in afterwards. *)
  val assemble_to : t -> dst_path:string -> unit Lwt.t

  (** {!assemble_to} for one range: writes those bytes into [dst_path] at the
      same offset, leaves the rest sparse, and returns the byte count — short
      only at end of file. Only the chunks the range covers are fetched, which
      is how a large file is opened without materializing it whole. [dst_path]
      is created even for a range past the end. *)
  val fetch_range :
    t -> dst_path:string -> offset:int -> length:int -> int Lwt.t

  val stat : t -> Unix.LargeFile.stats option Lwt.t

  (** Return the symlink target for a key whose manifest is a symlink, or [None]
      if the key is absent or is a regular file. *)
  val readlink : t -> string option Lwt.t

  (** Served from the local manifest mirror: file entries and subdirectory
      names. Directory mtimes are not tracked locally, hence [None]. *)
  val list_children :
    prefix:string ->
    (Backend.file_entry list * (string * float option) list) Lwt.t

  (** Recursive file listing under [prefix], served from the local mirror. *)
  val list_tree : prefix:string -> Backend.file_entry list Lwt.t

  (** A handle closed: queue the file for upload if it has staged edits. The
      staged manifest, not an open count, records what is owed, and it survives
      a restart. *)
  val close : t -> unit Lwt.t

  (** Delete staged bodies no staged manifest names — what a crash between
      staging a body and writing its manifest leaves behind — and prune the
      empty directories left in the staged manifest tree. Part of
      {!Replay.reconcile}: run at startup, never while writes may be staging, or
      it can collect a body a write is about to use. *)
  val reclaim_staged_orphans : unit -> unit Lwt.t

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

  (** Files with an active or queued upload. *)
  val uploads_pending : unit -> int

  (** The files being uploaded right now. *)
  val uploads_in_flight : unit -> in_flight list Lwt.t

  (** Bytes still owed by the upload queue. *)
  val uploads_pending_bytes : unit -> int64

  (** Whether uploads are parked. Queued work is kept while paused, and a
      restart resumes. *)
  val uploads_paused : unit -> bool

  val set_uploads_paused : bool -> unit

  (** Files written but not yet published, as this process tracks them: the
      in-memory view of what {!staged_count} finds on disk. *)

  (** Whether the metadata lock is held, and whether anything is queued behind
      it. Held with waiters is the usual cause of a mount that has stopped
      answering while its backend looks fine. *)
  val meta_locked : unit -> bool

  val meta_waiters : unit -> bool

  (** [Some (bytes_done, total_bytes)] while [key] is being pulled in whole;
      [None] when idle. *)
  val download_progress : t -> (int * int) option

  (** Drop [t]'s cached chunks, keeping its manifest: the file stays listed and
      re-fetches on demand. Unreference-blind; staged bodies are untouched. *)
  val evict : t -> unit Lwt.t

  val create : t -> unit Lwt.t

  (** Stage a whole file handed over by a frontend as [t]'s new content. *)
  val write_whole : t -> src_path:string -> unit Lwt.t

  val read : t -> buffer -> offset:int64 -> int Lwt.t
  val write : t -> buffer -> offset:int64 -> int Lwt.t
  val cancel_upload : t -> bool
  val truncate : t -> int64 -> unit Lwt.t
  val apply_delete : t -> unit Lwt.t

  (** Queue the staged content for upload under a freshly minted entry key. For
      work a WAL record already names, use {!resume_put}: minting a second key
      for it orphans the record that was already tracking it. *)
  val queue_put : t -> unit Lwt.t

  (** Re-queue a put under the entry key its record already holds, carrying the
      record forward so what it has already been through is not forgotten on
      every restart. [false] when nothing is staged for the key any more — the
      record names data that is gone, and the caller should discard it. *)
  val resume_put :
    t -> entry_key:Journal.Entry_key.t -> record:Wal.record -> bool Lwt.t

  val delete : t -> unit Lwt.t
  val mkdir : t -> unit Lwt.t
  val rmdir : t -> unit Lwt.t
  val rename : src:t -> dst:t -> unit Lwt.t
  val revert : ?version:string -> t -> unit Lwt.t
  val symlink : target:string -> t -> unit Lwt.t
  val apply_foreign_ops : Journal.op list -> unit Lwt.t
end
