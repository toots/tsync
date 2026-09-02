(* The manifest keys a copy publishes go through the inode scheme, and the read
   path wants the store it reads through; nothing in the copy names either, so
   both are wired here. *)
module Manifests = struct
  module Make (C : Conf_lwt.S) = Store_lwt.Make (C) (Layout_lwt.Inode.Make (C))
end

module Content = struct
  module Make (C : Conf_lwt.S) = Data_lwt.Make (C) (Remote_lwt.Make (C))
end

include
  Rsync.Over (Io_lwt.Core) (Io_lwt.Fs) (Io_lwt.Syscalls) (Folder_ids_lwt)
    (Remote_lwt)
    (Manifests)
    (File_store_lwt)
    (Manifests_lwt)
    (Checkout_lwt)
    (Content)
