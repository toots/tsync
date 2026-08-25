module Append = struct
  type t = Lwt_io.output_channel

  let open_out path = Lwt_io.open_file ~mode:Lwt_io.Output path
  let write t s = Lwt_io.write t s
  let close t = Lwt_io.close t

  (* Chars through the two channels rather than a read into a string, so a
     source larger than memory costs a buffer either way. *)
  let write_file t ~src =
    Lwt_io.with_file ~mode:Lwt_io.Input src (fun ic ->
        Lwt_io.write_chars t (Lwt_io.read_chars ic))
end

include Spool.Make (Io_lwt.Core) (Io_lwt.Fs) (Append)
