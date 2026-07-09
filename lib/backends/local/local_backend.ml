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
    Lwt_io.with_file ~mode:Lwt_io.Output tmp (fun oc -> Lwt_io.write oc data)
  in
  Lwt_unix.rename tmp path

let read_file path = Lwt_io.with_file ~mode:Lwt_io.Input path Lwt_io.read

(* FAT/exFAT reserved characters that cannot appear in a filename component.
   Keys are stored with these percent-encoded so the local backend works on
   exFAT and FAT32 as well as POSIX filesystems. *)
let is_fat_reserved = function
  | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '\\' -> true
  | c when Char.code c < 32 -> true
  | _ -> false

let encode_component s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      if is_fat_reserved c then
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

(* Apply f to each slash-delimited component of a key, leaving slashes intact. *)
let map_components f key =
  String.split_on_char '/' key |> List.map f |> String.concat "/"

let make ~root : (module Backend.S) =
  let resolve key =
    if key = "" then root
    else Filename.concat root (map_components encode_component key)
  in
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

    let head_opt ~key () =
      Lwt.catch
        (fun () ->
          let+ st = Lwt_unix.stat (resolve key) in
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

    let list_all ~prefix () =
      let base = resolve prefix in
      let rec walk path key_prefix =
        Lwt.catch
          (fun () ->
            let* names = readdir_list path in
            let+ entries =
              Lwt_list.fold_left_s
                (fun acc entry ->
                  let full_path = Filename.concat path entry in
                  let full_key = key_prefix ^ decode_component entry in
                  let* st = Lwt_unix.stat full_path in
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
                    let+ st = Lwt_unix.stat base in
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
      List.sort (fun a b -> String.compare a.Backend.key b.Backend.key) entries

    let list_directory ~prefix () =
      let+ all = list_all ~prefix () in
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
