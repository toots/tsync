open Lwt.Syntax

let rec mkdir_p path =
  let* exists = Lwt_unix_retry.file_exists path in
  if exists then Lwt.return_unit
  else
    let* () = mkdir_p (Filename.dirname path) in
    Lwt.catch
      (fun () -> Lwt_unix_retry.mkdir path 0o755)
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

(* Replace [path] with [data] atomically. The temp gets a name of its own —
   unique per process and per call — rather than [path ^ ".tmp"]: two writers of
   the same path (a read-ahead and a foreground read, or a second tsync process)
   would otherwise share one temp file and the loser's rename would fail ENOENT.
   The ".tmp" suffix is what the mirror walkers skip and reap. *)
let temp_seq = ref 0

let temp_path path =
  incr temp_seq;
  Filename.concat (Filename.dirname path)
    (Printf.sprintf ".tsync-tmp-%d-%d.tmp" (Unix.getpid ()) !temp_seq)

(* All or nothing: a [write] that fails part-way — a backend error mid-assembly,
   a full disk — leaves no temp file behind to be counted against the cache or
   swept later. *)
let write_then_rename path write =
  let tmp = temp_path path in
  Lwt.catch
    (fun () ->
      let* () = Lwt_unix_retry.with_file ~mode:Lwt_io.Output tmp write in
      Lwt_unix_retry.rename tmp path)
    (fun exn ->
      let* () =
        Lwt.catch
          (fun () -> Lwt_unix_retry.unlink tmp)
          (fun _ -> Lwt.return_unit)
      in
      Lwt.fail exn)

let atomic_write path data =
  write_then_rename path (fun oc -> Lwt_io.write oc data)

(* [atomic_write] for a body assembled from pieces: [write] appends each in
   turn, so the caller never holds the whole thing in memory. *)
let atomic_write_seq path write =
  write_then_rename path (fun oc -> write (Lwt_io.write oc))

let copy_file ~src ~dst =
  let* src_fd = Lwt_unix_retry.openfile src [Unix.O_RDONLY] 0 in
  Lwt.finalize
    (fun () ->
      let* dst_fd =
        Lwt_unix_retry.openfile dst
          [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC]
          0o644
      in
      Lwt.finalize
        (fun () ->
          let buffer = Bytes.create (1 lsl 20) in
          let rec copy () =
            let* bytes_read =
              Lwt_unix_retry.read src_fd buffer 0 (Bytes.length buffer)
            in
            if bytes_read = 0 then Lwt.return_unit
            else (
              let rec write_all pos =
                if pos >= bytes_read then copy ()
                else
                  let* written =
                    Lwt_unix_retry.write dst_fd buffer pos (bytes_read - pos)
                  in
                  write_all (pos + written)
              in
              write_all 0)
          in
          copy ())
        (fun () -> Lwt_unix_retry.close dst_fd))
    (fun () -> Lwt_unix_retry.close src_fd)

let readdir_list path =
  (* files_of_directory returns a stream; wrap the whole materialisation so
     a signal interrupting opendir or readdir retries from the start. *)
  Lwt_unix_retry.retry_eintr (fun () ->
      let+ names = Lwt_stream.to_list (Lwt_unix.files_of_directory path) in
      List.filter (fun name -> name <> "." && name <> "..") names)

let is_directory path =
  Lwt.catch
    (fun () ->
      let+ st = Lwt_unix_retry.stat path in
      st.Unix.st_kind = Unix.S_DIR)
    (fun _ -> Lwt.return_false)

(* [stat] as an option: a path that is absent — or that we cannot stat for any
   other reason — reads as [None]. Callers use the inode as an existence test,
   so every failure is the same answer. *)
let stat_opt path =
  Lwt.catch
    (fun () ->
      let+ st = Lwt_unix_retry.stat path in
      Some st)
    (fun _ -> Lwt.return_none)

let stat_opt_large path =
  Lwt.catch
    (fun () ->
      let+ st = Lwt_unix_retry.LargeFile.stat path in
      Some st)
    (fun _ -> Lwt.return_none)

(** lstat-based kind: [`Dir], [`File], or [`Symlink target]. [`Missing] for any
    error (dangling link, permission denied, etc.). *)
let lstat_kind path =
  Lwt.catch
    (fun () ->
      let* st = Lwt_unix_retry.lstat path in
      match st.Unix.st_kind with
        | Unix.S_DIR -> Lwt.return `Dir
        | Unix.S_LNK ->
            let+ target = Lwt_unix_retry.readlink path in
            `Symlink target
        | _ -> Lwt.return `File)
    (fun _ -> Lwt.return `Missing)

(* Recursively delete [path]; a missing path or unlink/rmdir failure is ignored.
   Uses [lstat] so a symlink is removed rather than followed. *)
let rec rm_rf path =
  Lwt.catch
    (fun () ->
      let* st = Lwt_unix_retry.lstat path in
      match st.Unix.st_kind with
        | Unix.S_DIR ->
            let* names = readdir_list path in
            let* () =
              Lwt_list.iter_s (fun n -> rm_rf (Filename.concat path n)) names
            in
            Lwt.catch
              (fun () -> Lwt_unix_retry.rmdir path)
              (function
                | Unix.Unix_error _ -> Lwt.return_unit | e -> Lwt.fail e)
        | _ ->
            Lwt.catch
              (fun () -> Lwt_unix_retry.unlink path)
              (function
                | Unix.Unix_error _ -> Lwt.return_unit | e -> Lwt.fail e))
    (function
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_unit
      | exn -> Lwt.fail exn)

let quiet f =
  Lwt.catch f (function
    | Unix.Unix_error _ -> Lwt.return_unit
    | exn -> Lwt.fail exn)

(* Deleting something that is already gone — or that we are not allowed to
   delete — is the outcome the caller wanted either way. Every cache and scratch
   path in the tree is re-derivable, so no unlink here is worth failing over. *)
let unlink_quiet path = quiet (fun () -> Lwt_unix_retry.unlink path)

(* Delete files under [dir] last modified before [cutoff] and prune directories
   left empty; [true] when [dir] holds nothing afterwards. Best-effort: a missing
   path or a failed unlink is ignored, and a file appearing mid-walk is simply
   seen by the next sweep. *)
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
              let+ () = quiet (fun () -> Lwt_unix_retry.rmdir child) in
              kept
            else Lwt.return (kept + 1)
          else
            let* mtime =
              Lwt.catch
                (fun () ->
                  let+ st = Lwt_unix_retry.stat child in
                  Some st.Unix.st_mtime)
                (fun _ -> Lwt.return_none)
            in
            match mtime with
              | Some m when m < cutoff ->
                  let+ () = quiet (fun () -> Lwt_unix_retry.unlink child) in
                  kept
              | _ -> Lwt.return (kept + 1))
        0 names
    in
    kept = 0
