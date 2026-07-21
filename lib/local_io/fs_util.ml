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
