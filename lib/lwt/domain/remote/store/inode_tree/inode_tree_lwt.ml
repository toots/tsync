(* The store the tree is read through, built here so that reading it asks for
   four calls rather than for a key scheme and a backend. *)
module Tree_store = struct
  module Make (C : Conf_lwt.S) = Store_lwt.Make (C) (Layout_lwt.Inode.Make (C))
end

include Inode_tree
include Inode_tree.Over (Io_lwt.Core) (Io_lwt.Bounded) (Tree_store)
