(* Snapshot test harness for tsync file operations. A scenario is a sequence of
   steps run against a fresh daemon instance (local backend, real Unix socket)
   over the JSON IPC protocol; [run] executes each scenario and prints a
   snapshot of the resulting state to stdout. Scenario files pair with a
   [.expected] snapshot; dune diffs the two under [dune test] and
   [dune test --auto-promote] refreshes them. *)

type step =
  | Write of { path : string; content : string }
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
  | Mark  (** Record the current time, usable later as an [Expire "mark"] cutoff. *)
  | Expire of string
      (** Run [Expire.expire]: prune versions older than a cutoff, then GC unused
          chunks. Selector is ["all"] (now), ["none"] (epoch), or ["mark"] (the
          time captured by the last [Mark] step — to expire across a boundary). *)
  | Drain
      (** Wait for queued uploads to finish. Also guarantees the next journal
          entry lands in a later millisecond, keeping snapshots deterministic
          (entry keys are ms-timestamped and collide within the same ms). *)
  | Sync
      (** Call [Sync_poller.sync_once]: read the journal, skip our own entries,
          apply any foreign entries — the same path the background poller takes.
      *)

type scenario = { name : string; steps : step list }
type two_client_step = A of step | B of step
type two_client_scenario = { name : string; steps : two_client_step list }

(** Run each scenario in order, printing its snapshot to stdout. Set
    [versioning] to enable version history (modify/rename/delete save a version).
*)
val run : ?versioning:bool -> scenario list -> unit

(** Run scenarios with two full client instances (separate cache, data dir,
    journal identity) sharing the same backend. Each step is tagged with the
    client it runs on; the final snapshot shows both clients' views followed by
    the shared backend state. *)
val run_two_client_scenarios :
  ?versioning:bool -> two_client_scenario list -> unit
