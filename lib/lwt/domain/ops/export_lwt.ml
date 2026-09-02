module Tree = struct
  type pool = Io_lwt.Bounded.t

  include Inode_tree_lwt
end

(* The read path wants the store it reads through; nothing in the export names
   one, so it is wired here. *)
module Content = struct
  module Make (C : Conf_lwt.S) = Data_lwt.Make (C) (Remote_lwt.Make (C))
end

include
  Export.Over (Io_lwt.Core) (Io_lwt.Fs) (Io_lwt.Syscalls) (Tree) (Checkout_lwt)
    (Staged_lwt.Manifest)
    (Content)
