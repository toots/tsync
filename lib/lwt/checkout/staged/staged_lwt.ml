(* The retrying syscalls plus the two names the layout keeps beside a directory:
   what both halves of the staged tree ask of a filesystem. *)
module Files = struct
  include Io_lwt.Fs
  include Cache_layout_lwt
end

module Syscalls = struct
  include Io_lwt.Retry

  type fd = Io_lwt.Syscalls.fd
end

module Body = Staged_body.Over (Io_lwt.Core) (Io_lwt.Fs) (Syscalls)
module Manifest = Staged_manifest.Over (Io_lwt.Core) (Files) (Io_lwt.Retry)
