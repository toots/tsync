include Checkout

module Files = struct
  include Io_lwt.Fs
  include Cache_layout_lwt
end

module Mirror = struct
  include Manifests_lwt

  let ensure_dirs = Manifests_lwt.ensure_dirs
end

include
  Checkout.Over (Io_lwt.Core) (Files) (Io_lwt.Retry) (Mirror)
    (Staged_lwt.Manifest)
    (Folder_ids_lwt)
