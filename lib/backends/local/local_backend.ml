open Lwt.Syntax

let mkdir_p = Fs_util.mkdir_p
let readdir_list = Fs_util.readdir_list

(* Each write stages to its own temp file (pid + sequence suffix) and renames it
   into place, so overlapping Lwt writes of the same key — e.g. the same chunk
   uploaded twice concurrently — never see a partial file; last rename wins. *)
let tmp_seq = ref 0

let write_file path data =
  let* () = Fs_util.ensure_parent path in
  incr tmp_seq;
  let tmp = Printf.sprintf "%s.%d.%d.tmp" path (Unix.getpid ()) !tmp_seq in
  let* () =
    Lwt_unix_retry.with_file ~mode:Lwt_io.Output tmp (fun oc ->
        Lwt_io.write oc data)
  in
  Lwt_unix_retry.rename tmp path

let read_file path =
  Lwt_unix_retry.with_file ~mode:Lwt_io.Input path Lwt_io.read

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
      Lwt.catch
        (fun () -> read_file (resolve key))
        (function
          | Unix.Unix_error (e, _, _) ->
              Lwt.fail
                (Backend.Backend_error
                   ("local get " ^ key ^ ": " ^ Unix.error_message e))
          | exn -> Lwt.fail exn)

    let get_opt ~key () =
      Lwt.catch
        (fun () ->
          let+ data = read_file (resolve key) in
          Some data)
        (function
          | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_none
          | Unix.Unix_error (e, _, _) ->
              Lwt.fail
                (Backend.Backend_error
                   ("local get " ^ key ^ ": " ^ Unix.error_message e))
          | exn -> Lwt.fail exn)

    let head_opt ~key () =
      Lwt.catch
        (fun () ->
          let+ st = Lwt_unix_retry.stat (resolve key) in
          match st with
            | { Unix.st_kind = Unix.S_DIR; st_mtime; _ } ->
                Some Backend.{ key; size = 0; last_modified = st_mtime }
            | { Unix.st_size; st_mtime; _ } ->
                Some Backend.{ key; size = st_size; last_modified = st_mtime })
        (function
          | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_none
          | exn -> Lwt.fail exn)

    let delete ~key () = Fs_util.rm_rf (resolve key)
    let delete_multi keys = Lwt_list.iter_s (fun key -> delete ~key ()) keys

    let copy ~src_key ~dst_key () =
      if is_dir_key src_key then mkdir_p (resolve dst_key)
      else
        let* data = read_file (resolve src_key) in
        write_file (resolve dst_key) data

    let list_all ?max_keys ~prefix () =
      let base = resolve prefix in
      let rec walk path key_prefix =
        Lwt.catch
          (fun () ->
            let* names = readdir_list path in
            let+ entries =
              Lwt_list.fold_left_s
                (fun acc entry ->
                  let full_path = Filename.concat path entry in
                  let full_key = key_prefix ^ entry in
                  let* st = Lwt_unix_retry.stat full_path in
                  match st.Unix.st_kind with
                    | Unix.S_REG ->
                        Lwt.return
                          (Backend.
                             {
                               key = full_key;
                               size = st.Unix.st_size;
                               last_modified = st.Unix.st_mtime;
                             }
                          :: acc)
                    | Unix.S_DIR ->
                        let+ sub = walk full_path (full_key ^ "/") in
                        sub @ acc
                    | _ -> Lwt.return acc)
                [] names
            in
            (* Surface empty directories as their marker key, matching the
               zero-byte marker object S3 lists for created directories. *)
            if names = [] && is_dir_key key_prefix then
              [Backend.{ key = key_prefix; size = 0; last_modified = 0. }]
            else entries)
          (function
            | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_nil
            | Unix.Unix_error (Unix.ENOTDIR, _, _) ->
                Lwt.catch
                  (fun () ->
                    let+ st = Lwt_unix_retry.stat base in
                    [
                      Backend.
                        {
                          key = prefix;
                          size = st.Unix.st_size;
                          last_modified = st.Unix.st_mtime;
                        };
                    ])
                  (fun _ -> Lwt.return_nil)
            | exn -> Lwt.fail exn)
      in
      let+ entries = walk base prefix in
      let entries =
        List.sort
          (fun a b -> String.compare a.Backend.key b.Backend.key)
          entries
      in
      match max_keys with
        | Some n when List.length entries > n ->
            List.filteri (fun i _ -> i < n) entries
        | _ -> entries

    (* One directory level only: a single [readdir] + [stat] per entry, so
       enumerating a folder costs O(entries in that folder), not O(whole subtree).
       (S3 needs the recursive [list_all] to synthesize directories; the local FS
       has real ones.) *)
    let list_directory ~prefix () =
      let base = resolve prefix in
      Lwt.catch
        (fun () ->
          let* names = readdir_list base in
          (* stat entries in parallel: on slow/networked storage the per-entry
             latency dominates, so concurrency (bounded by the Lwt thread pool)
             turns O(entries)·latency into a couple of round-trips. *)
          let+ entries =
            Lwt_list.map_p
              (fun name ->
                let full_path = Filename.concat base name in
                Lwt.catch
                  (fun () ->
                    let+ st = Lwt_unix_retry.stat full_path in
                    match st.Unix.st_kind with
                      | Unix.S_REG ->
                          `File
                            Backend.
                              {
                                key = prefix ^ name;
                                size = st.Unix.st_size;
                                last_modified = st.Unix.st_mtime;
                              }
                      | Unix.S_DIR -> `Dir (name, Some st.Unix.st_mtime)
                      | _ -> `Skip)
                  (function
                    (* entry vanished mid-listing (race): skip it *)
                    | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return `Skip
                    | exn -> Lwt.fail exn))
              names
          in
          let files =
            List.filter_map (function `File e -> Some e | _ -> None) entries
          in
          let dirs =
            List.filter_map (function `Dir d -> Some d | _ -> None) entries
          in
          (files, List.sort (fun (a, _) (b, _) -> String.compare a b) dirs))
        (function
          | Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) ->
              Lwt.return ([], [])
          | exn -> Lwt.fail exn)

    let share_url ~prefix:_ () = Lwt.return_none
  end)

let spec =
  Backend.
    [
      {
        name = "path";
        label = "Local path";
        typ = `String;
        default = None;
        secret = false;
      };
    ]

let () =
  Backend.register ~spec "local" (fun get ->
      let root =
        match get "path" with
          | Some p -> p
          | None -> failwith "local backend: missing field: path"
      in
      make ~root)
