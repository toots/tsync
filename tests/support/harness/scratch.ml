let rec rm_rf path =
  match Unix.lstat path with
    | exception Unix.Unix_error _ -> ()
    | st ->
        if st.Unix.st_kind = Unix.S_DIR then begin
          Array.iter
            (fun n -> rm_rf (Filename.concat path n))
            (Sys.readdir path);
          Unix.rmdir path
        end
        else Unix.unlink path

let dir name =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-%s-%d" name (Unix.getpid ()))
  in
  rm_rf path;
  Io_lwt.Fs.mkdir_p_sync path;
  path

let sub root name =
  let path = Filename.concat root name in
  Io_lwt.Fs.mkdir_p_sync path;
  path

let cleanup = rm_rf
