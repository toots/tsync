(* The queue draining outward and the replay applying inward, over this
   process's loop, its journal store and its intent log. *)
module Replay =
  Replay.Over (Io_lwt.Core) (Io_lwt.Bounded) (File_store) (Wal_lwt)
    (Staged_lwt.Manifest)

module Sync_poller =
  Sync_poller.Over (Io_lwt.Core) (Io_lwt.Clock) (File_store) (Replay)

module Sync_queue =
  Sync_queue.Over (Io_lwt.Core) (File_store) (Wal_lwt.Q) (Wal_lwt)
