let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let ensure_parent path = mkdir_p (Filename.dirname path)

let write_file path data =
  ensure_parent path;
  let tmp = path ^ ".tmp" in
  let oc = open_out_bin tmp in
  output_string oc data;
  close_out oc;
  Unix.rename tmp path

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = Bytes.create n in
  really_input ic s 0 n;
  close_in ic;
  Bytes.to_string s

let make ~root : (module Backend.S) =
  let resolve key = if key = "" then root else Filename.concat root key in
  (* Keys with a trailing slash are directory markers: S3 stores them as
     zero-byte objects, here they map to actual directories. *)
  let is_dir_key key =
    String.length key > 0 && key.[String.length key - 1] = '/'
  in
  (module struct
    let put ~key ~data () =
      if is_dir_key key then mkdir_p (resolve key)
      else write_file (resolve key) data

    let get ~key () =
      try read_file (resolve key)
      with Sys_error msg ->
        raise (Backend.Backend_error ("local get " ^ key ^ ": " ^ msg))

    let head_opt ~key () =
      let path = resolve key in
      match Unix.stat path with
        | { Unix.st_kind = Unix.S_DIR; st_mtime; _ } ->
            Some Backend.{ key; size = 0; last_modified = st_mtime }
        | { Unix.st_size; st_mtime; _ } ->
            Some Backend.{ key; size = st_size; last_modified = st_mtime }
        | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None

    let rec rm_rf path =
      match Unix.lstat path with
        | { Unix.st_kind = Unix.S_DIR; _ } -> (
            Array.iter
              (fun name -> rm_rf (Filename.concat path name))
              (Sys.readdir path);
            try Unix.rmdir path with Unix.Unix_error _ -> ())
        | _ -> ( try Unix.unlink path with Unix.Unix_error _ -> ())
        | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

    let delete ~key () =
      let path = resolve key in
      match Unix.lstat path with
        | { Unix.st_kind = Unix.S_DIR; _ } -> rm_rf path
        | _ -> (
            try Unix.unlink path
            with Unix.Unix_error (Unix.ENOENT, _, _) -> ())
        | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

    let delete_multi keys = List.iter (fun key -> delete ~key ()) keys

    let copy ~src_key ~dst_key () =
      if is_dir_key src_key then mkdir_p (resolve dst_key)
      else write_file (resolve dst_key) (read_file (resolve src_key))

    let list_all ~prefix () =
      let base = resolve prefix in
      let entries = ref [] in
      let rec walk path key_prefix =
        match Unix.opendir path with
          | dir ->
              let empty = ref true in
              (try
                 while true do
                   let entry = Unix.readdir dir in
                   if entry <> "." && entry <> ".." then begin
                     empty := false;
                     let full_path = Filename.concat path entry in
                     let full_key = key_prefix ^ entry in
                     match (Unix.stat full_path).Unix.st_kind with
                       | Unix.S_REG ->
                           let st = Unix.stat full_path in
                           entries :=
                             Backend.
                               {
                                 key = full_key;
                                 size = st.Unix.st_size;
                                 last_modified = st.Unix.st_mtime;
                               }
                             :: !entries
                       | Unix.S_DIR -> walk full_path (full_key ^ "/")
                       | _ -> ()
                   end
                 done
               with End_of_file -> ());
              Unix.closedir dir;
              (* Surface empty directories as their marker key, matching the
                 zero-byte marker object S3 lists for created directories. *)
              if !empty && is_dir_key key_prefix then
                entries :=
                  Backend.{ key = key_prefix; size = 0; last_modified = 0. }
                  :: !entries
          | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
          | exception Unix.Unix_error (Unix.ENOTDIR, _, _) -> (
              match Unix.stat base with
                | { Unix.st_size; st_mtime; _ } ->
                    entries :=
                      Backend.
                        {
                          key = prefix;
                          size = st_size;
                          last_modified = st_mtime;
                        }
                      :: !entries
                | exception _ -> ())
      in
      walk base prefix;
      List.sort (fun a b -> String.compare a.Backend.key b.Backend.key) !entries

    let list_directory ~prefix () =
      let all = list_all ~prefix () in
      let prefix_len = String.length prefix in
      let dirs = Hashtbl.create 16 in
      let files = ref [] in
      List.iter
        (fun (e : Backend.file_entry) ->
          if String.length e.key <= prefix_len then ()
          else begin
            let rest =
              String.sub e.key prefix_len (String.length e.key - prefix_len)
            in
            match String.index_opt rest '/' with
              | None -> files := e :: !files
              | Some i -> Hashtbl.replace dirs (String.sub rest 0 i) ()
          end)
        all;
      let subdirs = Hashtbl.fold (fun k () acc -> k :: acc) dirs [] in
      (List.rev !files, List.sort String.compare subdirs)
  end)

let () =
  Backend.register "local" (fun get ->
      let root =
        match get "path" with
          | Some p -> p
          | None -> failwith "local backend: missing field: path"
      in
      make ~root)
