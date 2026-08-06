(* Snapshot test harness for tsync file operations. A scenario is a sequence of
   steps run over the JSON IPC protocol against a fresh daemon (local backend,
   real Unix socket); [run] prints a snapshot of the resulting state. Each
   scenario file pairs with a [.expected] snapshot, diffed by [dune test] and
   refreshed by [dune test --auto-promote].

   Steps should mirror what a user would do: write a file, create a directory,
   import a folder. Steps encoding implementation details (specific chunk keys,
   internal state transitions) couple tests to the implementation. *)

type step =
  | Write of { path : string; content : string }
  | Symlink of { path : string; target : string }
      (** Create a symlink at [path] pointing to [target] via the IPC [symlink]
          action — the same path FUSE and FileProvider symlink creation takes.
      *)
  | Mkdir of string
  | Rmdir of string
  | Rename of { src : string; dst : string }
  | Delete of string
  | Evict of string
  | EnforceCache
      (** Run one best-effort cache-cap sweep (evict coldest clean files over
          the [max_cache] cap). *)
  | Restore of string
  | RevertVersion of { path : string; version : string option }
      (** Restore a saved version to the live location. [version] selects a
          timestamp; [None] restores the most recent. Content is not fetched. *)
  | Close of string
      (** Handle closed, the way FUSE [release] does: queue the upload a file
          with staged edits owes, and nothing otherwise. *)
  | ReadRange of { path : string; offset : int; len : int }
      (** Read [len] bytes at [offset], fetching only the chunks they need, and
          print the bytes returned. *)
  | FetchRange of { path : string; offset : int; len : int }
      (** Serve [len] bytes at [offset] the way the macOS File Provider asks for
          a piece of a large file. Prints bytes served, the destination file's
          length (everything before the range is a hole) and the bytes that
          landed. *)
  | WriteAt of { path : string; offset : int; content : string }
      (** Write [content] at [offset] through the staged write path
          (read-modify-write of a partially covered chunk). *)
  | Truncate of { path : string; size : int }
      (** Resize the file, up or down. *)
  | ShowChunks of string
      (** Print what backs the file — published chunk count, or staged slots as
          [S] (written locally) / [I] (still inherited) / [Z] (a hole from a
          grow) — plus how many of its chunks are in the local chunk store. *)
  | ShowChunkCache
      (** Print the whole chunk store's footprint: [chunks=n bytes=b]. *)
  | ShowStaged
      (** Print the staged tree's contents: manifests and the bodies they are
          supposed to be the only reference to. *)
  | ShowNames of string
      (** Print the entry names a readdir serves for a directory ([""] for the
          domain root), subdirectories with a trailing slash. A file with only
          staged edits must appear; internal markers must not. *)
  | Stat of string
      (** Query a path through the IPC [stat] action. A query changes nothing: a
          stat of something absent says so and leaves no trace. *)
  | Mark
      (** Record the current time, usable later as an [Expire "mark"] cutoff. *)
  | Expire of string
      (** Run [Expire.expire]: prune versions older than a cutoff, then GC
          unused chunks. Selector is ["all"] (now), ["none"] (epoch), or
          ["mark"] (the time captured by the last [Mark] step — to expire across
          a boundary). *)
  | Drain
      (** Wait for queued uploads to finish. Also puts the next journal entry in
          a later millisecond, keeping snapshots deterministic: entry keys are
          ms-timestamped and collide within one ms. *)
  | Sync
      (** Call [Sync_poller.sync_once]: read the journal, skip our own entries,
          apply any foreign entries — the same path the background poller takes.
      *)
  | DeleteRemoteChunk of { path : string; index : int }
      (** Delete chunk [index] of [path]'s manifest from the backend, behind the
          daemon's back. *)
  | CorruptRemoteChunk of { path : string; index : int }
      (** Overwrite chunk [index] of [path]'s manifest on the backend with
          garbage of the wrong size. *)
  | DeleteRemoteManifest of string
      (** Delete the file's manifest object from the backend. *)
  | StageWrite of { path : string; content : string }
      (** Replace the file's content locally with no upload queued — unsynced
          edits, the way a writer leaves a file between write and close. *)
  | CorruptCachedChunk of { path : string; index : int }
      (** Overwrite a cached chunk body with garbage behind the daemon's back,
          so it no longer hashes to its own name. *)
  | DeleteCachedChunk of { path : string; index : int }
      (** Delete a cached chunk body behind the daemon's back, as the cache cap
          may at any moment. *)
  | Recheck
      (** Run [Recheck.run] over the whole domain and print each file's status
          line plus a summary, then the chunk-store integrity pass. *)
  | RecoverStaged
      (** Finish or discard every unfinished WAL record, and adopt staged data
          no record names, the way a restart does after a crash. *)
  | CrashBeforeCommit of string
      (** Upload the bytes, record them as executed, and stop before publishing
          the journal entry — the window a kill -9 mid-upload leaves. The change
          is on the backend and no peer can see it. *)
  | StaleRecord
      (** Drop a record in the pre-state format naming a put whose data was
          never staged: what repeated replays left behind, 295 of them on one
          domain, before recovery kept one key per unit of work. *)
  | OrphanStagedBody
      (** Drop a staged body no manifest names into each body tree, the way a
          crash between staging a body and writing its manifest does. *)
  | ReclaimStaged
      (** Sweep staged bodies nothing references, as a restart does. *)
  | ClearCache
      (** Wipe the local cache the way a full resync does — manifest mirror,
          chunk store and scratch — keeping only the staged tree. *)
  | OnSecondary of step
      (** Apply a backend-damage step (delete/corrupt chunk, delete manifest) to
          the secondary backend instead of the primary. *)
  | ResyncRemote
      (** Run [Mirror.resync] from the primary to the other backends, printing
          the copied keys and a per-destination summary. Bytes are omitted:
          manifest objects embed mtimes, so their sizes are not deterministic.
      *)
  | LocalWrite of { path : string; content : string }
      (** Write [content] to [path] in the local staging directory (created on
          first use, reset after each [Import]). Parent directories are created
          automatically. *)
  | LocalMkdir of string
      (** Create a directory at [path] in the local staging directory. *)
  | LocalSymlink of { path : string; target : string }
      (** Create a symlink at [path] pointing to [target] in the local staging
          directory. *)
  | Import of { only : string list; exclude : string list; force_rehash : bool }
      (** Run [Import.run] on the current local staging directory, then reset it
          for the next batch. Populate it first with [LocalWrite], [LocalMkdir],
          and [LocalSymlink]. *)
  | ExportDir
      (** Run [Export.run] into a fresh temp folder, print per-file status
          lines, then dump the exported tree's contents. *)

type scenario = { name : string; steps : step list }
type two_client_step = A of step | B of step
type two_client_scenario = { name : string; steps : two_client_step list }

(** Run each scenario in order, printing its snapshot to stdout. Set
    [versioning] to enable version history (modify/rename/delete save a
    version). *)
val run :
  ?versioning:bool ->
  ?symlink_policy:[ `Keep | `Follow | `Skip ] ->
  scenario list ->
  unit

(** Run scenarios with two full client instances (separate cache, data dir,
    journal identity) sharing the same backend. Each step is tagged with the
    client it runs on; the final snapshot shows both clients' views followed by
    the shared backend state. *)
val run_two_client_scenarios :
  ?versioning:bool -> two_client_scenario list -> unit

(** Run each scenario (draining uploads), then snapshot the raw [list_dir] and
    [list_all] IPC responses — directory keys, logical size, content-hash etags,
    normalized mtime — the actual FileProvider listing contract. *)
val run_ipc : ?versioning:bool -> scenario list -> unit

(** Two clients on one backend: client A applies the steps, then client B's
    change feed is snapshotted from several anchors — a baseline (working
    delta), B's current cursor (up to date), and a pruned-past anchor (stale,
    which drives a full re-list). *)
val run_ipc_changes : ?versioning:bool -> scenario list -> unit

(** Snapshot the structure of the daemon's own report — the [stats] IPC action
    behind [tsync stats], and the same collection the http-proxy serves. Values
    that move between runs (pids, uptimes, paths, timings) are left out. *)
val run_stats : ?versioning:bool -> scenario list -> unit
