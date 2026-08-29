module Tree = struct
  type pool = Io_lwt.Bounded.t

  include Inode_tree_lwt
end

(* Both directions of the journal come from one place, so a resync drains and
   replays through the queue the daemon would have used. *)
module Sync = struct
  module Queue = Sync_lwt.Sync_queue.Make
  module Replay = Sync_lwt.Replay.Make
end

include
  Resync.Over (Io_lwt.Core) (Folder_ids_lwt) (Cache_layout_lwt) (Io_lwt.Bounded)
    (Tree)
    (File_store_lwt)
    (File_lwt)
    (Filing_lwt)
    (Sync)
