(* Snapshot test harness for tsync file operations. A scenario is a sequence of
   steps run against a fresh daemon instance (local backend, real Unix socket)
   over the JSON IPC protocol; [run] executes each scenario and prints a
   snapshot of the resulting state to stdout. Scenario files pair with a
   [.expected] snapshot; dune diffs the two under [dune test] and
   [dune test --auto-promote] refreshes them. *)

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
  | Restore of string
  | RevertVersion of { path : string; version : string option }
      (** Restore a saved version to the live location. [version] selects a
          timestamp; [None] restores the most recent. Content is not fetched. *)
  | Open of string
  | Close of string
      (** Track the file as open/closed, the way the FUSE layer does around user
          file handles. Foreign ops must never touch an open file. *)
  | Mark
      (** Record the current time, usable later as an [Expire "mark"] cutoff. *)
  | Expire of string
      (** Run [Expire.expire]: prune versions older than a cutoff, then GC
          unused chunks. Selector is ["all"] (now), ["none"] (epoch), or
          ["mark"] (the time captured by the last [Mark] step — to expire across
          a boundary). *)
  | Drain
      (** Wait for queued uploads to finish. Also guarantees the next journal
          entry lands in a later millisecond, keeping snapshots deterministic
          (entry keys are ms-timestamped and collide within the same ms). *)
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
  | DirtyWrite of { path : string; content : string }
      (** Local write not yet uploaded, the way the FUSE layer leaves a file
          between write and close: local data plus a [Dirty] sidecar. *)
  | ModifyCache of { path : string; content : string }
      (** Change the local cached data behind the daemon's back; the sidecar
          still describes the old content. *)
  | Recheck
      (** Run [Recheck.run] over the whole domain and print each file's status
          line plus a summary. *)
  | OnSecondary of step
      (** Apply a backend-damage step (delete/corrupt chunk, delete manifest) to
          the secondary backend instead of the primary. *)
  | ResyncRemote
      (** Run [Mirror.resync] from the primary to the other backends and print
          the copied keys plus a per-destination summary (bytes omitted:
          manifest objects embed mtimes, so their sizes are not deterministic).
      *)
  | ImportDir of (string * string) list
      (** Create a temp source folder with these (relative path, content) files,
          run [Import.run] on it, and print per-file status lines. *)
  | ImportDirExclude of {
      entries : (string * string) list;
      exclude : string list;
    }  (** Like [ImportDir] but passes [~exclude] patterns to [Import.run]. *)
  | ImportDirSymlinks of {
      files : (string * string) list;
      symlinks : (string * string) list;
    }
      (** Like [ImportDir] but also seeds (rel, target) symlinks in the source
          tree, exercising the [symlink_policy] configured on the scenario. *)
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
