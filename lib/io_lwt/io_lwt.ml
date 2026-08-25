(* The only module that names a scheduler. Everything above it takes what it
   needs as a parameter, so what runs the work is decided once, here. *)

module Core = struct
  type 'a t = 'a Lwt.t
  type 'a u = 'a Lwt.u

  let return = Lwt.return
  let bind = Lwt.bind
  let map = Lwt.map
  let catch = Lwt.catch
  let finalize = Lwt.finalize
  let fail = Lwt.fail
  let wait = Lwt.wait
  let wakeup_later = Lwt.wakeup_later
  let join = Lwt.join
  let map_p = Lwt_list.map_p
  let iter_p = Lwt_list.iter_p
end

module Syscalls = struct
  type fd = Lwt_unix.file_descr

  let file_exists = Lwt_unix.file_exists
  let stat = Lwt_unix.stat
  let lstat = Lwt_unix.lstat
  let readlink = Lwt_unix.readlink
  let symlink = Lwt_unix.symlink
  let rename = Lwt_unix.rename
  let unlink = Lwt_unix.unlink
  let link = Lwt_unix.link
  let mkdir = Lwt_unix.mkdir
  let rmdir = Lwt_unix.rmdir
  let openfile = Lwt_unix.openfile
  let close = Lwt_unix.close
  let read = Lwt_unix.read
  let write = Lwt_unix.write
  let pread = Lwt_unix.pread
  let pwrite = Lwt_unix.pwrite
  let pwrite_string = Lwt_unix.pwrite_string
  let utimes = Lwt_unix.utimes
  let fsync = Lwt_unix.fsync

  module LargeFile = Lwt_unix.LargeFile
end

module Bounded = Bounded.Make (Core)
module Retry = Retry.Make (Core) (Syscalls)

(* A channel rather than a descriptor, so it stays with the library whose
   channels they are. *)
let with_file ?buffer ?flags ?perm ~mode path f =
  Retry.retry_eintr (fun () ->
      Lwt_io.with_file ?buffer ?flags ?perm ~mode path f)
