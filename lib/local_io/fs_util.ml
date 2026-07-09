open Lwt.Syntax

(* Percent-encode characters that are reserved on FAT/exFAT/NTFS or are
   control characters, so local-backend paths are valid on any filesystem.
   Only individual name components are encoded; "/" is left as a separator. *)
let is_reserved = function
  | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '\\' -> true
  | c when Char.code c < 32 -> true
  | _ -> false

let encode_component s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      if is_reserved c then
        Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c))
      else Buffer.add_char buf c)
    s;
  Buffer.contents buf

let decode_component s =
  let n = String.length s in
  let buf = Buffer.create n in
  let i = ref 0 in
  while !i < n do
    if s.[!i] = '%' && !i + 2 < n then (
      let hex = String.sub s (!i + 1) 2 in
      match int_of_string_opt ("0x" ^ hex) with
        | Some code ->
            Buffer.add_char buf (Char.chr code);
            i := !i + 3
        | None ->
            Buffer.add_char buf s.[!i];
            incr i)
    else (
      Buffer.add_char buf s.[!i];
      incr i)
  done;
  Buffer.contents buf

let map_components f s =
  String.split_on_char '/' s |> List.map f |> String.concat "/"

let encode_key = map_components encode_component
let decode_key = map_components decode_component

let rec mkdir_p path =
  let* exists = Lwt_unix.file_exists path in
  if exists then Lwt.return_unit
  else
    let* () = mkdir_p (Filename.dirname path) in
    Lwt.catch
      (fun () -> Lwt_unix.mkdir path 0o755)
      (function
        | Unix.Unix_error (Unix.EEXIST, _, _) -> Lwt.return_unit
        | exn -> Lwt.fail exn)

let ensure_parent path = mkdir_p (Filename.dirname path)

let readdir_list path =
  let+ names = Lwt_stream.to_list (Lwt_unix.files_of_directory path) in
  List.filter (fun name -> name <> "." && name <> "..") names

let is_directory path =
  Lwt.catch
    (fun () ->
      let+ st = Lwt_unix.stat path in
      st.Unix.st_kind = Unix.S_DIR)
    (fun _ -> Lwt.return_false)

(** lstat-based kind: [`Dir], [`File], or [`Symlink target]. [`Missing] for any
    error (dangling link, permission denied, etc.). *)
let lstat_kind path =
  Lwt.catch
    (fun () ->
      let* st = Lwt_unix.lstat path in
      match st.Unix.st_kind with
        | Unix.S_DIR -> Lwt.return `Dir
        | Unix.S_LNK ->
            let+ target = Lwt_unix.readlink path in
            `Symlink target
        | _ -> Lwt.return `File)
    (fun _ -> Lwt.return `Missing)

(* Recursively delete [path]; a missing path or unlink/rmdir failure is ignored.
   Uses [lstat] so a symlink is removed rather than followed. *)
let rec rm_rf path =
  Lwt.catch
    (fun () ->
      let* st = Lwt_unix.lstat path in
      match st.Unix.st_kind with
        | Unix.S_DIR ->
            let* names = readdir_list path in
            let* () =
              Lwt_list.iter_s (fun n -> rm_rf (Filename.concat path n)) names
            in
            Lwt.catch
              (fun () -> Lwt_unix.rmdir path)
              (function
                | Unix.Unix_error _ -> Lwt.return_unit | e -> Lwt.fail e)
        | _ ->
            Lwt.catch
              (fun () -> Lwt_unix.unlink path)
              (function
                | Unix.Unix_error _ -> Lwt.return_unit | e -> Lwt.fail e))
    (function
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_unit
      | exn -> Lwt.fail exn)
