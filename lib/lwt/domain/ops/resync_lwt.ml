(* Both directions of the journal come from one place, so a resync drains and
   replays through the queue the daemon would have used. *)
module Sync = struct
  module Queue = Sync_lwt.Sync_queue
  module Replay = Sync_lwt.Replay
end

include
  Resync.Over (Io_lwt.Core) (Folder_ids_lwt) (Cache_layout_lwt) (Io_lwt.Bounded)
    (Inode_tree_lwt)
    (File_store_lwt)
    (File_lwt)
    (Checkout_lwt)
    (Sync)
