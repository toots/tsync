open Lwt.Syntax

(* [Fs.read_file_opt] answers [None] for both, and the difference decides
   whether a record is discarded or left for the next sweep. *)
module Files = struct
  include Io_lwt.Fs

  let read_file path =
    Lwt.catch
      (fun () ->
        let+ body =
          Io_lwt.Syscalls.retry_eintr (fun () ->
              Lwt_io.with_file ~mode:Lwt_io.Input path Lwt_io.read)
        in
        `Body body)
      (function
        | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return `Gone
        | exn -> Lwt.return (`Failed exn))
end

include Durable_queue
include Durable_queue.Make (Io_lwt.Core) (Io_lwt.Clock) (Io_lwt.Lock) (Files)
