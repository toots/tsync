include File

(* The tree is a parameter because callers disagree about what an absent entry
   means: one that keeps the whole domain locally reads it as "the domain does
   not have this", while one that pulls a folder when asked reads it as "not
   fetched yet". Neither answer belongs here. *)
module Over_tree (Ck : File.TREE with type 'a io := 'a Io_lwt.Core.t) =
  File.Over (Io_lwt.Core) (Io_lwt.Fs) (Io_lwt.Syscalls) (Io_lwt.Lock) (Wal_lwt)
    (Manifests_lwt)
    (Ck)
    (Staged_lwt.Manifest)
    (Data_lwt)
    (Folder_ids_lwt)

module Over = Over_tree (Checkout_lwt)

(* The one place the store modules are built, so everything above takes them
   rather than knowing which they are. *)
module Make_over
    (Ck : File.TREE with type 'a io := 'a Io_lwt.Core.t)
    (C : Conf_lwt.S) =
struct
  module O = Over_tree (Ck)
  module L = Layout_lwt.Inode.Make (C)

  include
    O.Make_with_layout (C) (L) (File_store_lwt.Make (C))
      (Store_lwt.Make (C) (L))
      (History_lwt.Make (C) (L))
      (Remote_lwt.Make_with_layout (C) (L))
end

module Make (C : Conf_lwt.S) = Make_over (Checkout_lwt) (C)
