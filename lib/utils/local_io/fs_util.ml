open Lwt.Syntax

let rec mkdir_p path =
  let* exists = Io_lwt.Retry.file_exists path in
  if exists then Lwt.return_unit
  else
    let* () = mkdir_p (Filename.dirname path) in
    Lwt.catch
      (fun () -> Io_lwt.Retry.mkdir path 0o755)
      (function
        | Unix.Unix_error (Unix.EEXIST, _, _) -> Lwt.return_unit
        | exn -> Lwt.fail exn)

let ensure_parent path = mkdir_p (Filename.dirname path)

(* The same, for the callers that run before there is an Lwt loop to run in:
   process startup, the CLI, the config writer. *)
let rec mkdir_p_sync ?(perm = 0o755) path =
  if not (Sys.file_exists path) then begin
    mkdir_p_sync ~perm (Filename.dirname path);
    try Unix.mkdir path perm with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

(* The descriptor keeps the inode alive without the name, so a caller that wants
   the bytes and not the file pays nothing for a kill landing here. *)
let open_and_unlink path =
  let fd = Unix.openfile path [Unix.O_RDONLY] 0 in
  Fun.protect
    ~finally:(fun () -> try Unix.unlink path with Unix.Unix_error _ -> ())
    (fun () -> fd)

(* [ESRCH] is the answer that matters; [EPERM] means a process we may not signal
   and is therefore alive. A reused pid reads as alive, so this retires a dead
   process's leavings rather than proving a live one's. *)
let pid_alive pid =
  match Unix.kill pid 0 with
    | () -> true
    | exception Unix.Unix_error (Unix.EPERM, _, _) -> true
    | exception _ -> false

(* All or nothing: a [fill] failing part-way leaves no temp file to be counted
   against the cache or swept later. *)
let with_temp_rename path fill =
  let tmp = Filename.temp_path path in
  Lwt.catch
    (fun () ->
      let* () = fill tmp in
      Io_lwt.Retry.rename tmp path)
    (fun exn ->
      let* () =
        Lwt.catch (fun () -> Io_lwt.Retry.unlink tmp) (fun _ -> Lwt.return_unit)
      in
      Lwt.fail exn)

let write_then_rename path write =
  with_temp_rename path (fun tmp ->
      Io_lwt.with_file ~mode:Lwt_io.Output tmp write)

let atomic_write path data =
  write_then_rename path (fun oc -> Lwt_io.write oc data)

(* [pwrite] carries its own offset and never touches the descriptor's shared
   position, so pieces may be written concurrently and out of order on one
   descriptor. *)
let atomic_write_at path ~size write =
  with_temp_rename path (fun tmp ->
      let* fd =
        Io_lwt.Retry.openfile tmp
          [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC]
          0o644
      in
      Lwt.finalize
        (fun () ->
          (* Allocated before any piece is produced, so a full disk fails before
             the bytes are paid for. *)
          let* () = Io_lwt.Retry.LargeFile.ftruncate fd (Int64.of_int size) in
          let put ~offset data =
            let total = Bigstringaf.length data in
            let rec go written =
              if written >= total then Lwt.return_unit
              else
                let* n =
                  Local_io.pwrite fd data ~file_offset:(offset + written)
                    written (total - written)
                in
                if n = 0 then
                  Lwt.fail
                    (Failure
                       (Printf.sprintf "short write to %s at offset %d" tmp
                          (offset + written)))
                else go (written + n)
            in
            go 0
          in
          write put)
        (fun () -> Io_lwt.Retry.close fd))

let copy_file ~src ~dst =
  let* src_fd = Io_lwt.Retry.openfile src [Unix.O_RDONLY] 0 in
  Lwt.finalize
    (fun () ->
      let* dst_fd =
        Io_lwt.Retry.openfile dst
          [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC]
          0o644
      in
      Lwt.finalize
        (fun () ->
          let buffer = Bytes.create (1 lsl 20) in
          let rec copy () =
            let* bytes_read =
              Io_lwt.Retry.read src_fd buffer 0 (Bytes.length buffer)
            in
            if bytes_read = 0 then Lwt.return_unit
            else (
              let rec write_all pos =
                if pos >= bytes_read then copy ()
                else
                  let* written =
                    Io_lwt.Retry.write dst_fd buffer pos (bytes_read - pos)
                  in
                  write_all (pos + written)
              in
              write_all 0)
          in
          copy ())
        (fun () -> Io_lwt.Retry.close dst_fd))
    (fun () -> Io_lwt.Retry.close src_fd)

let read_file_opt path =
  Lwt.catch
    (fun () ->
      let+ s = Io_lwt.with_file ~mode:Lwt_io.Input path Lwt_io.read in
      Some s)
    (fun _ -> Lwt.return_none)

let readdir_list path =
  (* files_of_directory returns a stream, so the whole materialisation is wrapped:
     a signal interrupting opendir or readdir retries from the start. *)
  Io_lwt.Retry.retry_eintr (fun () ->
      let+ names = Lwt_stream.to_list (Lwt_unix.files_of_directory path) in
      List.filter (fun name -> name <> "." && name <> "..") names)

(* A directory that is not there holds nothing, which is the same answer a caller
   sweeping a layout wants for one that is. Only [Unix_error] is swallowed: a
   parse or programming error still propagates. *)
let readdir_list_quiet path =
  Lwt.catch
    (fun () -> readdir_list path)
    (function Unix.Unix_error _ -> Lwt.return_nil | exn -> Lwt.fail exn)

let is_directory path =
  Lwt.catch
    (fun () ->
      let+ st = Io_lwt.Retry.stat path in
      st.Unix.st_kind = Unix.S_DIR)
    (fun _ -> Lwt.return_false)

(* Callers use the inode as an existence test, so every failure is the same
   answer. *)
let stat_opt path =
  Lwt.catch
    (fun () ->
      let+ st = Io_lwt.Retry.stat path in
      Some st)
    (fun _ -> Lwt.return_none)

let stat_opt_large path =
  Lwt.catch
    (fun () ->
      let+ st = Io_lwt.Retry.LargeFile.stat path in
      Some st)
    (fun _ -> Lwt.return_none)

(* [LargeFile], so a size past 2 GB is a number rather than [EOVERFLOW]. The
   size rides along because the lstat already has it: a caller sizing a walk
   would otherwise stat every entry a second time. *)
let lstat_kind path =
  Lwt.catch
    (fun () ->
      let* st = Io_lwt.Retry.LargeFile.lstat path in
      match st.Unix.LargeFile.st_kind with
        | Unix.S_DIR -> Lwt.return `Dir
        | Unix.S_LNK ->
            let+ target = Io_lwt.Retry.readlink path in
            `Symlink target
        | _ -> Lwt.return (`File st.Unix.LargeFile.st_size))
    (fun _ -> Lwt.return `Missing)

(* Missing paths and unlink/rmdir failures are ignored. [lstat], so a symlink is
   removed rather than followed. *)
let rec rm_rf path =
  Lwt.catch
    (fun () ->
      let* st = Io_lwt.Retry.lstat path in
      match st.Unix.st_kind with
        | Unix.S_DIR ->
            let* names = readdir_list path in
            let* () =
              Lwt_list.iter_s (fun n -> rm_rf (Filename.concat path n)) names
            in
            Lwt.catch
              (fun () -> Io_lwt.Retry.rmdir path)
              (function
                | Unix.Unix_error _ -> Lwt.return_unit | e -> Lwt.fail e)
        | _ ->
            Lwt.catch
              (fun () -> Io_lwt.Retry.unlink path)
              (function
                | Unix.Unix_error _ -> Lwt.return_unit | e -> Lwt.fail e))
    (function
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_unit
      | exn -> Lwt.fail exn)

let quiet f =
  Lwt.catch f (function
    | Unix.Unix_error _ -> Lwt.return_unit
    | exn -> Lwt.fail exn)

(* Already gone is the outcome the caller wanted, and every cache and scratch
   path is re-derivable, so no unlink here is worth failing over. *)
let unlink_quiet path = quiet (fun () -> Io_lwt.Retry.unlink path)

(* [true] when [dir] holds nothing afterwards. Best-effort: a missing path or
   failed unlink is ignored, and a file appearing mid-walk is seen by the next
   sweep. *)
let rec reap_older_than ~cutoff dir =
  let* is_dir = is_directory dir in
  if not is_dir then Lwt.return_true
  else
    let* names = readdir_list dir in
    let+ kept =
      Lwt_list.fold_left_s
        (fun kept name ->
          let child = Filename.concat dir name in
          let* is_dir = is_directory child in
          if is_dir then
            let* empty = reap_older_than ~cutoff child in
            if empty then
              let+ () = quiet (fun () -> Io_lwt.Retry.rmdir child) in
              kept
            else Lwt.return (kept + 1)
          else
            let* mtime =
              Lwt.catch
                (fun () ->
                  let+ st = Io_lwt.Retry.stat child in
                  Some st.Unix.st_mtime)
                (fun _ -> Lwt.return_none)
            in
            match mtime with
              | Some m when m < cutoff ->
                  let+ () = quiet (fun () -> Io_lwt.Retry.unlink child) in
                  kept
              | _ -> Lwt.return (kept + 1))
        0 names
    in
    kept = 0

type disk_space = { avail : int64; free : int64; total : int64 }

external statvfs : string -> int64 * int64 * int64 = "tsync_statvfs"

(* One syscall, so it is cheap enough for every status request. [None] rather
   than an exception when the path cannot be stat'd: capacity is not worth
   failing a report over. *)
let disk_space path =
  try
    let avail, free, total = statvfs path in
    Some { avail; free; total }
  with _ -> None
