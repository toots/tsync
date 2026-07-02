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
  | Drain
      (** Wait for queued uploads to finish. Also guarantees the next journal
          entry lands in a later millisecond, keeping snapshots deterministic
          (entry keys are ms-timestamped and collide within the same ms). *)

type scenario = { name : string; steps : step list }

(** Run each scenario in order, printing its snapshot to stdout. *)
val run : scenario list -> unit
