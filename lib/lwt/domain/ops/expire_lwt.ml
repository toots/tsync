(* The tree walk bounds itself with a pool; which pool that is belongs here. *)
module Tree = struct
  type pool = Io_lwt.Bounded.t

  include Inode_tree_lwt
end

include Expire.Over (Io_lwt.Core) (Tree) (File_store_lwt)
