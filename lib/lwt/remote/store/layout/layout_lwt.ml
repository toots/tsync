(* Applied once: the inode scheme reads folder ids from the local index, and
   that index is this machine's. *)
module type S = Layout.S with type 'a io := 'a Lwt.t

include Layout.Over (Io_lwt.Core) (Folder_ids_lwt)
