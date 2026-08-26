(* The manifest keys an import publishes go through the inode scheme, wired
   here so that nothing in the import names a key scheme at all. *)
module Manifests = struct
  module Make (C : Conf_lwt.S) = Store_lwt.Make (C) (Layout_lwt.Inode.Make (C))
end

include
  Import.Over (Io_lwt.Core) (Io_lwt.Fs) (Io_lwt.Retry) (Spool_lwt)
    (Folder_ids_lwt)
    (Remote_lwt)
    (Manifests)
    (File_store_lwt)
    (Manifests_lwt)
    (Checkout_lwt)
