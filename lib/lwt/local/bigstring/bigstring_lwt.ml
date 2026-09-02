open Lwt.Syntax

module Writer = struct
  let touch path =
    let* fd = Io_lwt.Syscalls.openfile path [Unix.O_WRONLY; Unix.O_CREAT] 0o644 in
    Io_lwt.Syscalls.close fd

  let write path t ~offset =
    let+ (_ : int) = Io_lwt.Fs.write path t ~offset in
    ()
end

include Bigstring
include Bigstring.Make (Io_lwt.Core) (Writer)
