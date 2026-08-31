include Lazy_checkout

(* [`Fail] rather than skipping an unreadable child: the caller prunes against
   this answer, and a listing missing a child it could not read is not evidence
   that the child is gone.

   No [refresh_index]: a browse is a read, and the store may be one this client
   is not allowed to write. *)
module Pull = struct
  module Make (C : Conf_lwt.S) = struct
    module Tree = Inode_tree_lwt.Make (C)

    let children ~folder_id () = Tree.children ~on_unusable:`Fail ~folder_id ()
  end
end

include
  Lazy_checkout.Over (Io_lwt.Core) (Checkout_lwt) (Pull) (Filing_lwt)
    (Folder_ids_lwt)
    (Manifests_lwt)
