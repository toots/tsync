let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
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
  let resolve key =
    if key = "" then root else Filename.concat root key
  in
  (module struct
    let put ?content_type:_ ~key ~data () = write_file (resolve key) data

    let get ~key () =
      try read_file (resolve key)
      with Sys_error msg ->
        raise (Backend.Backend_error ("local get " ^ key ^ ": " ^ msg))

    let head_opt ~key () =
      let path = resolve key in
      match Unix.stat path with
        | { Unix.st_size; st_mtime; _ } ->
            Some
              Backend.
                {
                  key;
                  size = st_size;
                  last_modified = st_mtime;
                  content_type = None;
                }
        | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None

    let delete ~key () =
      (try Unix.unlink (resolve key)
       with Unix.Unix_error (Unix.ENOENT, _, _) -> ())

    let delete_multi keys = List.iter (fun key -> delete ~key ()) keys

    let copy ~src_key ~dst_key () =
      write_file (resolve dst_key) (read_file (resolve src_key))

    let list_all ~prefix () =
      let base = resolve prefix in
      let entries = ref [] in
      let rec walk path key_prefix =
        match Unix.opendir path with
          | dir ->
              (try
                 while true do
                   let entry = Unix.readdir dir in
                   if entry <> "." && entry <> ".." then begin
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
                                 content_type = None;
                               }
                             :: !entries
                       | Unix.S_DIR -> walk full_path (full_key ^ "/")
                       | _ -> ()
                   end
                 done
               with End_of_file -> ());
              Unix.closedir dir
          | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
          | exception Unix.Unix_error (Unix.ENOTDIR, _, _) ->
              (match Unix.stat base with
                | { Unix.st_size; st_mtime; _ } ->
                    entries :=
                      Backend.
                        {
                          key = prefix;
                          size = st_size;
                          last_modified = st_mtime;
                          content_type = None;
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
