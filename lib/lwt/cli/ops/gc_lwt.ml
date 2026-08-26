(* The exclusion lock, on this kernel. Which errno means "someone else holds it"
   is a platform fact, so it is decided here rather than by the collection. *)
module Lockfile = struct
  type t = Lwt_unix.file_descr

  let take path =
    let open Lwt.Syntax in
    let* fd = Lwt_unix.openfile path [Unix.O_RDWR; Unix.O_CREAT] 0o644 in
    Lwt.catch
      (fun () ->
        let+ () = Lwt_unix.lockf fd Unix.F_TLOCK 0 in
        Some fd)
      (function
        | Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES | Unix.EDEADLK), _, _) ->
            let+ () = Lwt_unix.close fd in
            None
        | exn ->
            let* () = Lwt_unix.close fd in
            Lwt.fail exn)

  let drop fd =
    Lwt.catch
      (fun () -> Lwt_unix.close fd)
      (function Unix.Unix_error _ -> Lwt.return_unit | exn -> Lwt.fail exn)
end

include
  Gc.Over (Io_lwt.Core) (Io_lwt.Fs) (Io_lwt.Retry) (Io_lwt.Bounded) (Lockfile)
    (Io_lwt.Clock)
    (Collection_lwt)
