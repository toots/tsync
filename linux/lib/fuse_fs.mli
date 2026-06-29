type context = {
  store : File_store.t;
  domain_name : string;
  domain_prefix : string;
  mount_point : string;
  sync_queue : Sync_queue.t;
}

(** When [true], locally-cached files are evicted from disk after a successful
    upload. Persisted as a sentinel file; [true] if the file exists at startup.
*)
val auto_evict : bool ref

(** Record [entry_key] as the latest journal entry pending a version bump. The
    version flusher thread calls [File_store.bump_version] every 2 seconds. *)
val set_pending_version : string -> unit

(** Remove the in-memory stat cache entry for [key], forcing the next [getattr]
    to re-stat from the local file or S3. *)
val cache_invalidate : string -> unit

(** Mount the FUSE filesystem described by [ctx] and block until unmounted.
    Starts background threads for IPC, journal version flushing, and remote
    change polling before entering the FUSE event loop. *)
val mount : context -> string array -> unit
