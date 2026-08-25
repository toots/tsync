(* What a frontend can do to a file in a domain, as a signature on its own: the
   upload queue's replay and the change poller are written against it, so a test
   can drive them with a stub instead of a whole domain. *)

type buffer = Io_lwt.Fs.buffer

(** A file the upload queue is working on right now. [rel] names it from the
    domain root, the way its reader sees it; [body] is where its bytes are on
    disk, for anything that wants to look at them. *)
type in_flight = {
  name : string;
  rel : string;
  body : string option;
  size : int64 option;
}

(** A file whose chunks are coming off a backend because something is reading
    it. [bytes] is what this read has pulled so far, [size] the whole file. *)
type downloading = {
  d_name : string;
  d_rel : string;
  d_bytes : int;
  d_size : int;
  d_seconds : float;
  d_rate : float;
}

module type S = sig
  type t = Logical_key.t

  val manifest_path : t -> string
  val rel_key : t -> string

  (** What this machine has published for [t]. *)
  val published_here : t -> Manifest.t option Lwt.t

  (** {!published_here}, falling back to the store when there is no local
      sidecar, so a file this client has never cached still resolves to its
      logical size and mtime rather than the manifest object's byte size. *)
  val published : t -> Manifest.t option Lwt.t

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

  (** Served from the local manifest mirror: what it holds for each item, and
      subdirectory names. Directory mtimes are not tracked locally, hence
      [None]. *)
  val list_children :
    prefix:t -> (Checkout.listed list * (string * float option) list) Lwt.t

  (** Recursive file listing under [prefix], served from the local mirror. *)
  val list_tree : prefix:t -> Checkout.listed list Lwt.t

  (** A handle closed: queue the file for upload if it has staged edits. The
      staged manifest, not an open count, records what is owed, and it survives
      a restart. *)
  val close : t -> unit Lwt.t

  (** Delete staged bodies no staged manifest names — what a crash between
      staging a body and writing its manifest leaves behind — and prune the
      empty directories left in the staged manifest tree.

      Once per machine, before anything serves the domain. A body is judged an
      orphan by the absence of a manifest naming it, which is also what a body
      being staged right now looks like, so a second process running this
      collects bytes a live write is about to use. *)
  val reclaim_staged_orphans : unit -> unit Lwt.t

  (** Keep the chunk store under [C.max_cache]; never touches staged data. *)
  val enforce_chunk_cap : unit -> unit Lwt.t

  (** [(chunks, bytes)] held in the chunk store. *)
  val chunk_stats : unit -> (int * int) Lwt.t

  (** [t]'s content: staged edits if any, else what was published. *)
  val resolve :
    t ->
    [ `Staged of Staged_manifest.staged * Manifest.t option
    | `Published of Manifest.t ]
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

  (** The files being uploaded right now. *)
  val uploads_in_flight : unit -> in_flight list Lwt.t

  (** The files being read whose content is coming off a backend right now.
      Distinct from {!download_progress}, which follows a whole-file
      materialization. Synchronous because the table behind it is mutated by
      reads on this same loop. *)
  val downloading_now : unit -> downloading list

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

  (** Stop an upload of [t] that is under way. [false] when none was. Not only
      for a caller that asks: a write to a file being sent stops the send, or a
      manifest is published for content torn out from under it. *)
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
