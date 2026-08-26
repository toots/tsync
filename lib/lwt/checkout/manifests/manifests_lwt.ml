(* Applied once: the per-domain memo of which manifest describes a file is one
   table however many places name it. *)
module Files = struct
  include Io_lwt.Fs
  include Cache_layout_lwt
end

include Manifests.Over (Io_lwt.Core) (Files) (Staged_lwt.Manifest)
