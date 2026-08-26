include File

module Over =
  File.Over (Io_lwt.Core) (Io_lwt.Fs) (Io_lwt.Retry) (Io_lwt.Lock) (Wal_lwt)
    (Manifests_lwt)
    (Checkout_lwt)
    (Staged_lwt.Manifest)
    (Data_lwt)
    (Folder_ids_lwt)

(* The one place the store modules are built, so everything above takes them
   rather than knowing which they are. *)
module Make (C : Conf_lwt.S) = struct
  module L = Layout_lwt.Inode.Make (C)

  include
    Over.Make_with_layout (C) (L) (File_store_lwt.Make (C))
      (Store_lwt.Make (C) (L))
      (History_lwt.Make (C) (L))
      (Remote.Make_with_layout (C) (L))
end
