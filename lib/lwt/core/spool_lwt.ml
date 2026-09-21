module Append = struct
  type t = Lwt_io.output_channel

  let open_out path = Lwt_io.open_file ~mode:Lwt_io.Output path
  let write t s = Lwt_io.write t s
  let close t = Lwt_io.close t
end

include Spool.Make (Io_lwt.Core) (Io_lwt.Fs) (Append)
