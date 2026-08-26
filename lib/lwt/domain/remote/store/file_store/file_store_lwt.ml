(* Applied once: the debouncer in front of a domain's cursor is per object, so
   every module touching the journal shares one. *)
module Manifests = struct
  module Make (C : Conf_lwt.S) = Store_lwt.Make (C) (Layout_lwt.Inode.Make (C))
end

include File_store
include File_store.Over (Io_lwt.Core) (Io_lwt.Lock) (Io_lwt.Clock) (Manifests)
