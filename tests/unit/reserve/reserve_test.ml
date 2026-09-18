(* Whether a filesystem can reserve is its own to say, so it is asked once and
   both claims are made against the answer: the file is sized either way, and
   owns its blocks wherever the platform could give them. *)

open Check

let root = Scratch.dir "reserve"
let size = 4 * 1024 * 1024

let allocated_bytes path =
  let ic =
    Unix.open_process_in (Printf.sprintf "du -k %s" (Filename.quote path))
  in
  let line = input_line ic in
  ignore (Unix.close_process_in ic);
  1024 * Scanf.sscanf line "%d" Fun.id

let with_new_file name f =
  let path = Filename.concat root name in
  Lwt_main.run
    (let open Lwt.Syntax in
     let* fd =
       Lwt_unix.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644
     in
     Lwt.finalize (fun () -> f fd) (fun () -> Lwt_unix.close fd));
  path

let can_reserve =
  match
    with_new_file "probe" (fun fd ->
        Io_lwt.Fs_primitives.reserve ~size:(Int64.of_int size) fd)
  with
    | (_ : string) -> true
    | exception Unix.Unix_error ((Unix.EOPNOTSUPP | Unix.ENOSYS), _, _) -> false

let () =
  case "reserve";
  step "filesystem reserves: %b" can_reserve;
  let path =
    with_new_file "body" (fun fd ->
        Io_lwt.Fs.reserve ~size:(Int64.of_int size) fd)
  in
  check "the file is sized" ((Unix.stat path).Unix.st_size = size);
  check "and owns its blocks where the filesystem could give them"
    ~why:(fun () -> Printf.sprintf "%d allocated" (allocated_bytes path))
    ((not can_reserve) || allocated_bytes path >= size);
  Scratch.cleanup root;
  report ~expected:2 ()
