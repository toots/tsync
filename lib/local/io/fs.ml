(** A filesystem, as far as anything above it needs one.

    Most of what is here is not a syscall: a recursive mkdir, a temp-and-rename,
    a walk that removes a tree. It is written once against {!Io.S} and the few
    operations a platform actually owes, which is {!PRIMITIVES}. *)

(* Before there is a loop to run in: process startup, the CLI, the config
   writer. *)
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

(** What a platform owes beyond {!Syscalls.S}: whole files, a directory's names,
    and bigstrings on a descriptor. Everything else below is built from these.
*)
module type PRIMITIVES = sig
  type 'a io
  type fd

  (** [None] for any failure, a missing path included. *)
  val read_file_opt : string -> string option io

  val write_file : string -> string -> unit io

  (** Without [.] and [..]. *)
  val readdir_list : string -> string list io

  (** At the descriptor's own position, which they advance. *)
  val bread : fd -> Bigstringaf.t -> int -> int -> int io

  val bwrite : fd -> Bigstringaf.t -> int -> int -> int io

  (** The offset travels with the call and the descriptor's own position is
      untouched, so ranges of one file may be moved concurrently through one
      descriptor.

      These need not yield, and under Lwt they do not. *)
  val pread : fd -> Bigstringaf.t -> file_offset:int -> int -> int -> int io

  val pwrite : fd -> Bigstringaf.t -> file_offset:int -> int -> int -> int io
end

module type S = Fs_intf.S

module Make
    (Io : Io.S)
    (Sys : Syscalls.S with type 'a io := 'a Io.t)
    (P : PRIMITIVES with type 'a io := 'a Io.t and type fd := Sys.fd) =
struct
  type fd = Sys.fd

  module Sys = Syscalls.Make (Io) (Sys)
  open Io_syntax.Make (Io)

  type buffer = Bigstringaf.t

  let read_file_opt = P.read_file_opt
  let readdir_list = P.readdir_list
  let pread = P.pread
  let pwrite = P.pwrite

  let rec mkdir_p path =
    let* exists = Sys.file_exists path in
    if exists then Io.return ()
    else
      let* () = mkdir_p (Filename.dirname path) in
      Io.catch
        (fun () -> Sys.mkdir path 0o755)
        (function
          | Unix.Unix_error (Unix.EEXIST, _, _) -> Io.return ()
          | exn -> Io.fail exn)

  let ensure_parent path = mkdir_p (Filename.dirname path)

  (* All or nothing: a [fill] failing part-way leaves no temp file to be counted
     against the cache or swept later. *)
  let with_temp_rename path fill =
    let tmp = Filename.temp_path path in
    Io.catch
      (fun () ->
        let* () = fill tmp in
        Sys.rename tmp path)
      (fun exn ->
        let* () = Io.catch (fun () -> Sys.unlink tmp) (fun _ -> Io.return ()) in
        Io.fail exn)

  let atomic_write path data =
    with_temp_rename path (fun tmp -> P.write_file tmp data)

  let atomic_write_at path ~size write =
    with_temp_rename path (fun tmp ->
        let* fd =
          Sys.openfile tmp [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644
        in
        Io.finalize
          (fun () ->
            (* Allocated before any piece is produced, so a full disk fails
               before the bytes are paid for. *)
            let* () = Sys.LargeFile.ftruncate fd (Int64.of_int size) in
            let put ~offset data =
              let total = Bigstringaf.length data in
              let rec go written =
                if written >= total then Io.return ()
                else
                  let* n =
                    P.pwrite fd data ~file_offset:(offset + written) written
                      (total - written)
                  in
                  if n = 0 then
                    Io.fail
                      (Failure
                         (Printf.sprintf "short write to %s at offset %d" tmp
                            (offset + written)))
                  else go (written + n)
              in
              go 0
            in
            write put)
          (fun () -> Sys.close fd))

  let copy_file ~src ~dst =
    let* src_fd = Sys.openfile src [Unix.O_RDONLY] 0 in
    Io.finalize
      (fun () ->
        let* dst_fd =
          Sys.openfile dst [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644
        in
        Io.finalize
          (fun () ->
            let buffer = Bytes.create (1 lsl 20) in
            let rec copy () =
              let* bytes_read =
                Sys.read src_fd buffer 0 (Bytes.length buffer)
              in
              if bytes_read = 0 then Io.return ()
              else (
                let rec write_all pos =
                  if pos >= bytes_read then copy ()
                  else
                    let* written =
                      Sys.write dst_fd buffer pos (bytes_read - pos)
                    in
                    write_all (pos + written)
                in
                write_all 0)
            in
            copy ())
          (fun () -> Sys.close dst_fd))
      (fun () -> Sys.close src_fd)

  (* A directory that is not there holds nothing, which is the same answer a
     caller sweeping a layout wants for one that is. Only [Unix_error] is
     swallowed: a parse or programming error still propagates. *)
  let readdir_list_quiet path =
    Io.catch
      (fun () -> readdir_list path)
      (function Unix.Unix_error _ -> Io.return [] | exn -> Io.fail exn)

  let is_directory path =
    Io.catch
      (fun () ->
        let+ st = Sys.stat path in
        st.Unix.st_kind = Unix.S_DIR)
      (fun _ -> Io.return false)

  (* Callers use the inode as an existence test, so every failure is the same
     answer. *)
  let stat_opt path =
    Io.catch
      (fun () ->
        let+ st = Sys.stat path in
        Some st)
      (fun _ -> Io.return None)

  let stat_opt_large path =
    Io.catch
      (fun () ->
        let+ st = Sys.LargeFile.stat path in
        Some st)
      (fun _ -> Io.return None)

  (* [LargeFile], so a size past 2 GB is a number rather than [EOVERFLOW]. The
     size rides along because the lstat already has it: a caller sizing a walk
     would otherwise stat every entry a second time. *)
  let lstat_kind path =
    Io.catch
      (fun () ->
        let* st = Sys.LargeFile.lstat path in
        match st.Unix.LargeFile.st_kind with
          | Unix.S_DIR -> Io.return `Dir
          | Unix.S_LNK ->
              let+ target = Sys.readlink path in
              `Symlink target
          | _ -> Io.return (`File st.Unix.LargeFile.st_size))
      (fun _ -> Io.return `Missing)

  (* Missing paths and unlink/rmdir failures are ignored. [lstat], so a symlink
     is removed rather than followed. *)
  let rec rm_rf path =
    Io.catch
      (fun () ->
        let* st = Sys.lstat path in
        match st.Unix.st_kind with
          | Unix.S_DIR ->
              let* names = readdir_list path in
              let* () =
                iter_s (fun n -> rm_rf (Filename.concat path n)) names
              in
              Io.catch
                (fun () -> Sys.rmdir path)
                (function Unix.Unix_error _ -> Io.return () | e -> Io.fail e)
          | _ ->
              Io.catch
                (fun () -> Sys.unlink path)
                (function Unix.Unix_error _ -> Io.return () | e -> Io.fail e))
      (function
        | Unix.Unix_error (Unix.ENOENT, _, _) -> Io.return ()
        | exn -> Io.fail exn)

  let quiet f =
    Io.catch f (function
      | Unix.Unix_error _ -> Io.return ()
      | exn -> Io.fail exn)

  (* Already gone is the outcome the caller wanted, and every cache and scratch
     path is re-derivable, so no unlink here is worth failing over. *)
  let unlink_quiet path = quiet (fun () -> Sys.unlink path)

  (* [true] when [dir] holds nothing afterwards. Best-effort: a missing path or
     failed unlink is ignored, and a file appearing mid-walk is seen by the next
     sweep. *)
  let rec reap_older_than ~cutoff dir =
    let* is_dir = is_directory dir in
    if not is_dir then Io.return true
    else
      let* names = readdir_list dir in
      let+ kept =
        fold_left_s
          (fun kept name ->
            let child = Filename.concat dir name in
            let* is_dir = is_directory child in
            if is_dir then
              let* empty = reap_older_than ~cutoff child in
              if empty then
                let+ () = quiet (fun () -> Sys.rmdir child) in
                kept
              else Io.return (kept + 1)
            else
              let* mtime =
                Io.catch
                  (fun () ->
                    let+ st = Sys.stat child in
                    Some st.Unix.st_mtime)
                  (fun _ -> Io.return None)
              in
              match mtime with
                | Some m when m < cutoff ->
                    let+ () = quiet (fun () -> Sys.unlink child) in
                    kept
                | _ -> Io.return (kept + 1))
          0 names
      in
      kept = 0

  let zero buf ~pos ~len =
    Bigarray.Array1.fill (Bigarray.Array1.sub buf pos len) '\000'

  (* Opened per call, so a caller holding only a path can move a range without
     tracking a descriptor. *)
  let rw op path flags buf ~offset =
    let size = Bigarray.Array1.dim buf in
    if size = 0 then Io.return 0
    else
      let* fd = Sys.openfile path flags 0o644 in
      Io.finalize
        (fun () ->
          let* _ = Sys.LargeFile.lseek fd offset Unix.SEEK_SET in
          let rec loop pos =
            if pos >= size then Io.return pos
            else
              let* n = op fd buf pos (size - pos) in
              if n = 0 then Io.return pos else loop (pos + n)
          in
          loop 0)
        (fun () -> Sys.close fd)

  let read path buf ~offset = rw P.bread path [Unix.O_RDONLY] buf ~offset

  let write path buf ~offset =
    rw P.bwrite path [Unix.O_RDWR; Unix.O_CREAT] buf ~offset
end
