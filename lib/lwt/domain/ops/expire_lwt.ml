(* The tree walk bounds itself with a pool; which pool that is belongs here. *)
include Expire.Over (Io_lwt.Core) (Inode_tree_lwt) (File_store_lwt)
