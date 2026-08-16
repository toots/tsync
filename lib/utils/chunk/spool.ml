open Lwt.Syntax

type t = { path : string; out : Lwt_io.output_channel }

let create ~dir ~name =
  let* () = Fs_util.mkdir_p dir in
  let path = Fs_util.temp_path (Filename.concat dir name) in
  let+ out = Lwt_io.open_file ~mode:Lwt_io.Output path in
  { path; out }

let path t = t.path
let append t s = Lwt_io.write t.out s
let close t = Lwt_io.close t.out

let append_file t ~src =
  Lwt_io.with_file ~mode:Lwt_io.Input src (fun ic ->
      Lwt_io.write_chars t.out (Lwt_io.read_chars ic))

let close_quiet t =
  Lwt.catch (fun () -> Lwt_io.close t.out) (fun _ -> Lwt.return_unit)

let seal t =
  let* () = Lwt_io.close t.out in
  let+ st = Lwt_unix.stat t.path in
  Chunk.map_file ~path:t.path ~offset:0 ~len:st.Unix.st_size

let drop t =
  let* () = close_quiet t in
  Fs_util.unlink_quiet t.path

let reap ~dir =
  let* names = Fs_util.readdir_list_quiet dir in
  Lwt_list.iter_s
    (fun name ->
      if Fs_util.is_temp_name name then
        Fs_util.unlink_quiet (Filename.concat dir name)
      else Lwt.return_unit)
    names
