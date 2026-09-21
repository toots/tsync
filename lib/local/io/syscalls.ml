(* A signal arriving mid-syscall makes it fail with EINTR rather than doing
   anything wrong, so every wrapper below just calls again; the daemon takes
   SIGCHLD and SIGWINCH often enough for this to matter.

   The rule is here and the calls are the platform's, which is what {!S} is
   for: it lists what a platform owes, in the names and argument order the
   caller already knows. *)

module type S = Syscalls_intf.S

module Make (Io : Io.S) (Sys : S with type 'a io := 'a Io.t) = struct
  type fd = Sys.fd

  let rec retry_eintr f =
    Io.catch f (function
      | Unix.Unix_error (Unix.EINTR, _, _) -> retry_eintr f
      | exn -> Io.fail exn)

  let file_exists path = retry_eintr (fun () -> Sys.file_exists path)
  let stat path = retry_eintr (fun () -> Sys.stat path)
  let lstat path = retry_eintr (fun () -> Sys.lstat path)
  let readlink path = retry_eintr (fun () -> Sys.readlink path)

  let symlink ?to_dir target path =
    retry_eintr (fun () -> Sys.symlink ?to_dir target path)

  let rename src dst = retry_eintr (fun () -> Sys.rename src dst)
  let unlink path = retry_eintr (fun () -> Sys.unlink path)

  (* Unlike rename, this fails with EEXIST rather than replacing, which is what
     makes it a claim. *)
  let link src dst = retry_eintr (fun () -> Sys.link src dst)
  let mkdir path mode = retry_eintr (fun () -> Sys.mkdir path mode)
  let rmdir path = retry_eintr (fun () -> Sys.rmdir path)

  let openfile path flags mode =
    retry_eintr (fun () -> Sys.openfile path flags mode)

  let close fd = retry_eintr (fun () -> Sys.close fd)
  let read fd buf ofs len = retry_eintr (fun () -> Sys.read fd buf ofs len)
  let write fd buf ofs len = retry_eintr (fun () -> Sys.write fd buf ofs len)

  let pread fd buf ~file_offset ofs len =
    retry_eintr (fun () -> Sys.pread fd buf ~file_offset ofs len)

  let pwrite fd buf ~file_offset ofs len =
    retry_eintr (fun () -> Sys.pwrite fd buf ~file_offset ofs len)

  let pwrite_string fd data ~file_offset ofs len =
    retry_eintr (fun () -> Sys.pwrite_string fd data ~file_offset ofs len)

  let utimes path atime mtime =
    retry_eintr (fun () -> Sys.utimes path atime mtime)

  let fsync fd = retry_eintr (fun () -> Sys.fsync fd)

  module LargeFile = struct
    let stat path = retry_eintr (fun () -> Sys.LargeFile.stat path)
    let lstat path = retry_eintr (fun () -> Sys.LargeFile.lstat path)
    let fstat fd = retry_eintr (fun () -> Sys.LargeFile.fstat fd)

    let ftruncate fd size =
      retry_eintr (fun () -> Sys.LargeFile.ftruncate fd size)

    let lseek fd ofs whence =
      retry_eintr (fun () -> Sys.LargeFile.lseek fd ofs whence)
  end
end
