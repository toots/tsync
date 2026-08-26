(* Applied once: the chunk buffers and the reads in flight are one budget per
   chunk prefix, however many places name a domain — see {!Remote.Over}. *)
module Syscalls = struct
  include Io_lwt.Retry

  type fd = Io_lwt.Syscalls.fd
end

module Inode_layout = Layout_lwt.Inode
module Manifests = Store_lwt
module Versions = History_lwt

include
  Remote.Over (Io_lwt.Core) (Io_lwt.Bounded) (Syscalls) (Inode_layout)
    (Manifests)
    (Versions)
    (Collection_lwt)
    (Corruption_lwt)
