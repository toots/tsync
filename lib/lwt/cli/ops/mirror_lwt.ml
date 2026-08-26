module Tree = struct
  type pool = Io_lwt.Bounded.t

  include Inode_tree_lwt
end

include
  Mirror.Over (Io_lwt.Core) (Spool_lwt) (Io_lwt.Bounded) (Tree) (Collection_lwt)
