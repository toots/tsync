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

module Clock = struct
  let sleep = Lwt_unix.sleep
  let with_timeout = Lwt_unix.with_timeout
  let is_timeout exn = exn = Lwt_unix.Timeout
end

module Bounded = Bounded.Make (Core)
module Retry = Retry.Make (Core) (Syscalls)

module Fs_primitives = struct
  let read_file_opt path =
    Lwt.catch
      (fun () ->
        Lwt.map Option.some
          (Retry.retry_eintr (fun () ->
               Lwt_io.with_file ~mode:Lwt_io.Input path Lwt_io.read)))
      (fun _ -> Lwt.return_none)

  let write_file path data =
    Retry.retry_eintr (fun () ->
        Lwt_io.with_file ~mode:Lwt_io.Output path (fun oc ->
            Lwt_io.write oc data))

  (* A stream, so the whole materialisation is wrapped: a signal interrupting
     opendir or readdir retries from the start. *)
  let readdir_list path =
    Retry.retry_eintr (fun () ->
        Lwt.map
          (List.filter (fun name -> name <> "." && name <> ".."))
          (Lwt_stream.to_list (Lwt_unix.files_of_directory path)))

  let bread = Lwt_bytes.read
  let bwrite = Lwt_bytes.write

  external unix_pread :
    Unix.file_descr -> Bigstringaf.t -> int -> int -> int -> int
    = "caml_tsync_pread_bytecode" "caml_tsync_pread"

  external unix_pwrite :
    Unix.file_descr -> Bigstringaf.t -> int -> int -> int -> int
    = "caml_tsync_pwrite_bytecode" "caml_tsync_pwrite"

  (* Already resolved: the stub blocks, and no caller has yet wanted a
     scheduling point here. *)
  let positioned op fd buf ~file_offset pos len =
    Lwt.return (op (Lwt_unix.unix_file_descr fd) buf file_offset pos len)

  let pread fd buf ~file_offset pos len =
    positioned unix_pread fd buf ~file_offset pos len

  let pwrite fd buf ~file_offset pos len =
    positioned unix_pwrite fd buf ~file_offset pos len
end

module Fs = struct
  include Tsync_io.Fs
  include Tsync_io.Fs.Make (Core) (Syscalls) (Fs_primitives)
end
