(* What the session memo of known chunk keys is allowed to hold.

   The memo skips a HEAD for a chunk this session already placed, which is what
   makes re-importing a tree cheap. It is keyed per chunk and nothing evicts it
   on its own, so its size follows the bytes a session moves rather than the
   working set: a command uploading a terabyte holds an entry for every distinct
   chunk in it, for as long as it runs.

   The cap is asserted in both directions, since a memo that stored nothing
   would satisfy a bound as well as a working one does. *)

open Lwt.Syntax

let chunk_size = 4096
let cache_chunk_size = 2 * chunk_size
let root = Filename.temp_dir "tsync-known-chunks" ""
let backend_root = Filename.concat root "backend"
let failures = ref 0

let check name ok =
  if ok then Printf.printf "%s: ok\n%!" name
  else begin
    incr failures;
    Printf.printf "%s: FAILED\n%!" name
  end

module C = struct
  let versioning = false
  let client_name = "Test"
  let domain_name = "test"
  let domain_prefix = "tsync/test/manifests/"
  let chunk_prefix = "tsync/test/chunks/"
  let versions_prefix = "tsync/test/versions/"
  let journal_prefix = "tsync/test/journal/"
  let cursor_key = "tsync/test/cursor"
  let shares_prefix = "tsync/shares/"

  let store =
    Backend.make ~backend_type:"local"
      ~get_field:(fun _ -> Some backend_root)
      ()

  let members = [Backend.member ~name:"local" store]
  let cache_root = Filename.concat root "cache"
  let data_dir = Filename.concat root "data"
  let socket_path = Filename.concat root "s.sock"
  let max_uploads = 4
  let max_chunk_buffers = 4
  let max_downloads = 8
  let chunk_size = Some chunk_size
  let cache_chunk_size = Some cache_chunk_size
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module R = Remote.Make (C)

(* Distinct bytes per chunk, so every chunk is its own key and dedup does not
   quietly reduce what the memo is asked to hold. *)
let write_file path ~chunks =
  let oc = open_out_bin path in
  for i = 0 to chunks - 1 do
    output_string oc (Printf.sprintf "%08d" i);
    output_string oc (String.make (chunk_size - 8) (Char.chr (65 + (i mod 26))))
  done;
  close_out oc

let upload name ~chunks =
  let path = Filename.concat root name in
  write_file path ~chunks;
  let* st = Lwt_unix.stat path in
  let+ (_ : Manifest.t) =
    R.upload ~key:(C.domain_prefix ^ name) ~src_path:path
      ~mtime:st.Unix.st_mtime ~chunk_size ()
  in
  ()

let () =
  Lwt_main.run
    (let* () = upload "small" ~chunks:8 in
     let held = R.known_chunk_count () in
     check (Printf.sprintf "an upload fills the memo (%d)" held) (held > 0);

     (* Past the cap, with room either side of it. *)
     Remote.set_max_known 20;
     let* () = upload "big" ~chunks:64 in
     let held = R.known_chunk_count () in
     check
       (Printf.sprintf "72 chunks uploaded under a cap of 20 leave %d" held)
       (held <= 20);
     check "and the memo is not simply empty" (held > 0);

     if !failures > 0 then exit 1;
     Lwt.return_unit)
