let rec retry_eintr f =
  Lwt.catch f (function
    | Unix.Unix_error (Unix.EINTR, _, _) -> retry_eintr f
    | exn -> Lwt.fail exn)

let file_exists path = retry_eintr (fun () -> Lwt_unix.file_exists path)
let stat path = retry_eintr (fun () -> Lwt_unix.stat path)
let lstat path = retry_eintr (fun () -> Lwt_unix.lstat path)
let readlink path = retry_eintr (fun () -> Lwt_unix.readlink path)
let symlink target path = retry_eintr (fun () -> Lwt_unix.symlink target path)
let rename src dst = retry_eintr (fun () -> Lwt_unix.rename src dst)
let unlink path = retry_eintr (fun () -> Lwt_unix.unlink path)
let mkdir path mode = retry_eintr (fun () -> Lwt_unix.mkdir path mode)
let rmdir path = retry_eintr (fun () -> Lwt_unix.rmdir path)

let openfile path flags mode =
  retry_eintr (fun () -> Lwt_unix.openfile path flags mode)

let close fd = retry_eintr (fun () -> Lwt_unix.close fd)
let read fd buf ofs len = retry_eintr (fun () -> Lwt_unix.read fd buf ofs len)
let write fd buf ofs len = retry_eintr (fun () -> Lwt_unix.write fd buf ofs len)

let pread fd buf ~file_offset ofs len =
  retry_eintr (fun () -> Lwt_unix.pread fd buf ~file_offset ofs len)

let pwrite_string fd data ~file_offset ofs len =
  retry_eintr (fun () -> Lwt_unix.pwrite_string fd data ~file_offset ofs len)

let utimes path atime mtime =
  retry_eintr (fun () -> Lwt_unix.utimes path atime mtime)

let fsync fd = retry_eintr (fun () -> Lwt_unix.fsync fd)

module LargeFile = struct
  let stat path = retry_eintr (fun () -> Lwt_unix.LargeFile.stat path)

  let ftruncate fd size =
    retry_eintr (fun () -> Lwt_unix.LargeFile.ftruncate fd size)

  let lseek fd ofs whence =
    retry_eintr (fun () -> Lwt_unix.LargeFile.lseek fd ofs whence)
end

let pwrite fd buf ~file_offset ofs len =
  retry_eintr (fun () -> Lwt_unix.pwrite fd buf ~file_offset ofs len)

let with_file ?buffer ?flags ?perm ~mode path f =
  retry_eintr (fun () -> Lwt_io.with_file ?buffer ?flags ?perm ~mode path f)
