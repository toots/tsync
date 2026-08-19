(* What a staged sidecar means on disk, across the versions of it that exist.

   The offset is what lets one body hold a whole cache group, and it is omitted
   when zero -- which is what makes a sidecar written before offsets existed
   read correctly rather than needing converting. A sidecar from a newer build
   is set aside instead, since guessing at fields it does not have would lose
   unsynced edits. *)

open Lwt.Syntax

let root = "/tmp/tsync-staged-codec-test"

module C : Conf.S = struct
  let versioning = false
  let client_name = "test"
  let domain_name = "codecdom"
  let domain_prefix = "tsync/codecdom/manifests/"
  let chunk_prefix = "tsync/codecdom/chunks/"
  let versions_prefix = "tsync/codecdom/versions/"
  let journal_prefix = "tsync/codecdom/journal/"
  let cursor_key = "tsync/codecdom/cursor"
  let shares_prefix = "tsync/shares/"

  let store =
    Backend.make ~backend_type:"local"
      ~get_field:(fun _ -> Some (root ^ "/store"))
      ()

  let members = [Backend.member ~name:"local" store]
  let cache_root = root ^ "/cache"
  let data_dir = root ^ "/data"
  let socket_path = ""
  let max_uploads = 1
  let max_chunk_buffers = 1
  let max_downloads = 1
  let chunk_size = Some 8
  let cache_chunk_size = Some 24
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module Mf = Manifest.Make (C)

let key = C.domain_prefix ^ "file.txt"

let staged =
  {
    Manifest.s_name = "file.txt";
    s_size = 24L;
    s_mtime = 315532800.;
    s_chunk_size = 8;
    (* Three chunks of one 24-byte group: one body, three offsets. *)
    s_slots =
      [|
        Manifest.Staged { uuid = "aaaa"; offset = 0 };
        Manifest.Staged { uuid = "aaaa"; offset = 8 };
        Manifest.Staged { uuid = "aaaa"; offset = 16 };
      |];
    s_whole = None;
    s_published = None;
  }

let sidecar () =
  let dir =
    Cache_layout.staged_manifests_dir ~cache_root:C.cache_root C.domain_name
  in
  let rec find dir =
    Array.fold_left
      (fun found name ->
        match found with
          | Some _ -> found
          | None ->
              let path = Filename.concat dir name in
              if Sys.is_directory path then find path
              else if Filename.check_suffix path ".bad" then None
              else Some path)
      None (Sys.readdir dir)
  in
  find dir

let patch f =
  match sidecar () with
    | None -> print_endline "no sidecar on disk"
    | Some path ->
        let ic = open_in_bin path in
        let body = really_input_string ic (in_channel_length ic) in
        close_in ic;
        let oc = open_out_bin path in
        output_string oc (f body);
        close_out oc

let show label =
  let+ st = Mf.read_staged key in
  match st with
    | None -> Printf.printf "%s: no staged manifest\n" label
    | Some st ->
        let slot = function
          | Manifest.Staged { uuid; offset } ->
              Printf.sprintf "%s@%d" uuid offset
          | Manifest.Inherit -> "inherit"
          | Manifest.Zero -> "zero"
        in
        Printf.printf "%s: %s\n" label
          (String.concat " "
             (Array.to_list (Array.map slot st.Manifest.s_slots)));
        Printf.printf "%s: bodies %s\n" label
          (String.concat "," (Manifest.body_uuids st.Manifest.s_slots))

let replace ~sub ~by s =
  let n = String.length sub in
  let rec go i =
    if i + n > String.length s then s
    else if String.sub s i n = sub then
      String.sub s 0 i ^ by ^ String.sub s (i + n) (String.length s - i - n)
    else go (i + 1)
  in
  go 0

let main () =
  let* (_ : Unix.process_status) = Lwt_unix.system ("rm -rf " ^ root) in
  let* () = Mf.write_staged key staged in
  let* () = show "written and read back" in

  (* A sidecar from before offsets existed: no "o", and a body of its own per
     chunk rather than one shared across the group. *)
  patch (fun s ->
      replace ~sub:{|,"o":8|} ~by:"" (replace ~sub:{|,"o":16|} ~by:"" s));
  patch (fun s ->
      replace ~sub:{|"u":"aaaa"|} ~by:{|"u":"b2"|}
        (replace ~sub:{|"u":"aaaa"|} ~by:{|"u":"b1"|}
           (replace ~sub:{|"u":"aaaa"|} ~by:{|"u":"b0"|} s)));
  patch (fun s -> replace ~sub:{|"v":2|} ~by:{|"v":1|} s);
  let* () = show "a sidecar written before offsets" in

  (* From a build this one does not know. *)
  patch (fun s -> replace ~sub:{|"v":1|} ~by:{|"v":3|} s);
  let* () = show "a sidecar from a newer build" in
  Printf.printf "set aside: %b\n" (sidecar () = None);
  Lwt.return_unit

let () = Lwt_main.run (main ())
