module Files = struct
  include Cache_layout_lwt
  include Io_lwt.Fs

  type fd = Io_lwt.Syscalls.fd
end

module Syscalls = struct
  include Io_lwt.Retry

  type fd = Io_lwt.Syscalls.fd
end

include
  Data.Over (Io_lwt.Core) (Files) (Syscalls) (Io_lwt.Lock) (Io_lwt.Bounded)
    (Manifests_lwt)
