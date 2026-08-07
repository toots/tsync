(** The domain file operations backed by the local manifest mirror, the staged
    tree and the chunk store. {!File_ops.S} is the interface they satisfy. *)

module Make_with_layout (C : Conf.S) (Sq : Sync_queue.S) (L : Layout.S) :
  File_ops.S

module Make (C : Conf.S) (Sq : Sync_queue.S) : File_ops.S
