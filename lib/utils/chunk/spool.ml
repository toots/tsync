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
  (* Nothing here can recover the ops the file held; what naming it buys is a
     caller that fails saying which spool went missing, rather than an uncaught
     [ENOENT] from a stat with no context. *)
  let* st =
    Lwt.catch
      (fun () -> Lwt_unix.stat t.path)
      (function
        | Unix.Unix_error (Unix.ENOENT, _, _) ->
            Lwt.fail_with
              (Printf.sprintf "spool %s vanished before it was read" t.path)
        | exn -> Lwt.fail exn)
  in
  Lwt.return (Chunk.map_file ~path:t.path ~offset:0 ~len:st.Unix.st_size)

let drop t =
  let* () = close_quiet t in
  Fs_util.unlink_quiet t.path

(* Only what a dead process left: a concurrent run's spool is live, and deleting
   it takes its ops with it and crashes it at seal. *)
let reap ~dir =
  let* names = Fs_util.readdir_list_quiet dir in
  Lwt_list.iter_s
    (fun name ->
      match Fs_util.temp_owner name with
        | Some pid when not (Fs_util.pid_alive pid) ->
            Fs_util.unlink_quiet (Filename.concat dir name)
        | _ -> Lwt.return_unit)
    names
