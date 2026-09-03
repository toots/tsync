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
  | ReadRange of {
      path : string;
      offset : int;
      len : int;
      stream : string option;
    }
      (** Read [len] bytes at [offset], fetching only the chunks they need, and
          print the bytes returned. [stream] names the descriptor reading, so
          interleaved readers of one file each keep their own place for the
          read-ahead heuristic. *)
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
  | ShowLocal of string
  | CreateUnder of { parent : string; name : string }
      (** Query a path through the IPC [stat] action. A query changes nothing: a
          stat of something absent says so and leaves no trace. *)
  | Mark
      (** Record the current time, usable later as an [Expire "mark"] cutoff. *)
  | Expire of string
      (** Run [Retention.expire]: drop trashed folders, versions and journal
          entries older than a cutoff. Selector is ["all"] (now), ["none"]
          (epoch), or ["mark"] (the time captured by the last [Mark] step — to
          expire across a boundary). Leaves the chunks it orphaned behind;
          collecting those is [Gc]. *)
  | PurgeTrashed of string
      (** Run [Retention.purge_trashed]: drop one trashed folder and its subtree
          now, whatever its age. Leaves the chunks it orphaned behind, as
          [Expire] does. *)
  | Gc  (** Run [Gc.run]: collect the chunks nothing references any more. *)
  | GcVerify
      (** The same collection with [~verify], which holds each live chunk
          against its own name as it keeps it. *)
  | GcMark
      (** Collect only as far as the end of marking, leaving the collection
          open. Paired with [GcClose], this is how a scenario gets to act —
          write a file, read one — with the store mid-collection, which is where
          the interesting races are. *)
  | GcClose  (** Finish a collection [GcMark] left open. *)
  | GcAbort  (** Abandon an open collection, keeping every chunk it holds. *)
  | Drain
      (** Wait for queued uploads to finish. Also puts the next journal entry in
          a later millisecond, keeping snapshots deterministic: entry keys are
          ms-timestamped and collide within one ms. *)
  | Uploads of [ `Paused | `Running ]
      (** Park the upload workers, or let them go again. A scenario that leaves
          a write unsynced has to hold the queue rather than outrun it: how far
          an upload got before a later write cancelled it is otherwise decided
          by how fast the disk is, and the backend snapshot says so.

          A paused queue still owes what is on it, so [Drain] only returns once
          the scenario has let it run. *)
  | Sync
      (** Call [Sync_poller.sync_once]: read the journal, skip our own entries,
          apply any foreign entries — the same path the background poller takes.
      *)
  | HideNewestJournalEntry
      (** Take the newest journal object out of the store, as if its upload were
          still in flight while later entries land. *)
  | UnhideJournalEntry  (** Put it back, behind whatever was published since. *)
  | DeleteRemoteChunk of { path : string; index : int }
      (** Delete chunk [index] of [path]'s manifest from the backend, behind the
          daemon's back. *)
  | CorruptRemoteChunk of { path : string; index : int }
      (** Overwrite chunk [index] of [path]'s manifest on the backend with
          garbage of the wrong size. *)
  | ScrambleRemoteChunk of { path : string; index : int }
      (** Overwrite chunk [index] of [path]'s manifest on the backend with
          different bytes of the {i same} size, which nothing short of hashing
          the body can tell from the real one. Written through the store's own
          [put], so the store files its own marker for it. *)
  | ScrambleBackendFile of { path : string; index : int }
      (** Same damage as {!ScrambleRemoteChunk}, done straight to the file
          rather than through the store's [put] — so nothing notices at the
          time. What bit rot on a disk looks like, and what only a pass that
          reads the bytes back can find. *)
  | ListCorrupted
      (** Print what {!Corruption.list} reports, prefixed by a count so a
          listing that finds nothing is still visible. Names any store nothing
          checks: a store that never looked and a store that found nothing both
          list zero markers, and only one of those is good news. *)
  | RequestVerify
      (** Ask each store to check all of its chunks —
          {!Backend_lwt.Store.verify_all} — and print what each answered. A
          [local] store cannot, which is the case worth pinning: the command
          built on this has to fail rather than report a check that never ran.
      *)
  | RescanCorrupted
      (** Drop the memo behind {!Corruption.is_marked}. What the few-second TTL
          does on its own in a running daemon; a snapshot must not sleep for it.
      *)
  | Repair
      (** Run [Repair.run]: rewrite each marked chunk from a copy that hashes to
          its key, and print what became of every one. *)
  | DeleteRemoteManifest of string
      (** Delete the file's manifest object from the backend. *)
  | StageWrite of { path : string; content : string }
      (** Replace the file's content locally with no upload queued — unsynced
          edits, the way a writer leaves a file between write and close. *)
  | DeleteCachedChunk of { path : string; index : int }
      (** Delete a cached chunk body behind the daemon's back, as the cache cap
          may at any moment. *)
  | ForgetFolderId of string
      (** Drop a directory's local id marker, leaving the mirror holding the
          folder and its files but no name to offer a frontend. What a client
          that replayed a put whose mkdir predates its cursor is left with. *)
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
      (** Wipe the local cache — manifest mirror, folder index, chunk store and
          applied entries — keeping only the staged tree, which is what a client
          that lost its cache still holds. *)
  | OnSecondary of step
      (** Apply a backend-damage step (delete/corrupt chunk, delete manifest) to
          the secondary backend instead of the primary. *)
  | ResyncRemote
      (** Run [Checkout.resync] from the primary to the other backends, printing
          the copied keys and a per-destination summary. Bytes are omitted:
          manifest objects embed mtimes, so their sizes are not deterministic.
      *)
  | ResyncScoped of { path : string option }
      (** [ResyncRemote] narrowed to one folder and the chunks its files name.
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

(** Run each scenario (draining uploads), then snapshot the raw [list_dir]
    responses — directory keys, logical size, content-hash etags, normalized
    mtime — and the same root walked in pages, which is the FileProvider listing
    contract. *)
val run_ipc : ?versioning:bool -> scenario list -> unit

(** Two clients on one backend: client A applies the steps, B syncs them, and
    then B's change feed is snapshotted from several anchors — a baseline
    (working delta), B's current cursor (up to date), and a pruned-past anchor
    (stale, which drives a full re-list).

    B syncs first because the feed answers with what this client has applied:
    that is what lets a reader trust that every item an op names is already in
    the mirror. *)
val run_ipc_changes : ?versioning:bool -> scenario list -> unit

(** Snapshot the structure of the daemon's own report — the [stats] IPC action
    behind [tsync status], and the same collection the http-proxy serves. Values
    that move between runs (pids, uptimes, paths, timings) are left out. *)
val run_stats : ?versioning:bool -> scenario list -> unit
