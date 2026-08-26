(* The loop a marker has to close: dedup skips a write when the store already
   holds the key, a corrupt chunk is the right size so a presence check answers
   yes, and every later file naming that chunk would inherit the bad bytes.

   Damage is written through the store's own [put], which is what makes the
   marker appear at all. *)

open Lwt.Syntax
open Check

let chunk_size = 4096
let cache_chunk_size = chunk_size
let root = Scratch.dir "corruption"
let backend_root = Filename.concat root "backend"

(* Exit status is the whole assertion for a test with no snapshot, so a run that
   fell out early — an exception inside the Lwt chain, a fixture that never
   built — must not be able to leave 0 behind. *)
let expected_checks = 7

module C = struct
  let versioning = false
  let client_name = "Test"
  let domain_name = "test"
  let domain_prefix = "tsync/test/manifests/"
  let chunk_prefix = "tsync/test/chunks/"
  let versions_prefix = "tsync/test/versions/"
  let journal_prefix = "tsync/test/journal/"
  let cursor_key = Stored_key.in_space ~prefix:"tsync/test/" "cursor"
  let shares_prefix = "tsync/shares/"

  let store =
    Backend_lwt.make ~backend_type:"local"
      ~get_field:(function "path" -> Some backend_root | _ -> None)
      ()

  let members = [Backend.member ~name:"local" ~local_path:backend_root store]
  let cache_root = Filename.concat root "cache"
  let data_dir = Filename.concat root "data"
  let socket_path = Filename.concat root "s.sock"
  let max_uploads = 4
  let max_chunk_buffers = 4
  let max_downloads = 16
  let chunk_size = Some chunk_size
  let cache_chunk_size = Some cache_chunk_size
  let max_cache : int option = None
  let symlink_policy = `Keep
  let read_only = false
end

module Lk = Logical_key.Make (C)
module R = Remote.Make (C)
module Corrupt = Corruption.Make (C)
module B = (val C.store : Backend_lwt.Store)

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

(* One chunk exactly, so the manifest names a single key to talk about. *)
let body = String.init chunk_size (fun i -> Char.chr (i * 7 mod 251))

let upload name contents =
  let key = Lk.file @@ name in
  let src = Filename.concat root name in
  write_file src contents;
  R.upload ~key ~src_path:src ~mtime:0. ~chunk_size ()

let listed () =
  let+ report = Corrupt.list () in
  List.map (fun (e : Corruption.entry) -> e.Corruption.chunk_key) report.entries

let () =
  Lwt_main.run
    (let* manifest = upload "a.bin" body in
     let chunk_key = Manifest.key manifest 0 in
     let backend_key =
       Stored_key.in_space ~prefix:C.chunk_prefix
         (Chunk_layout.relative_path chunk_key)
     in

     let* marks = listed () in
     check "a good upload is marked by nothing" (marks = []);

     let* report = Corrupt.list () in
     check "and the store says it is checking"
       (report.Corruption.unverified = [] && report.Corruption.unreachable = []);

     (* Same length, different bytes: what a size comparison cannot see. *)
     let scrambled =
       String.map (fun c -> Char.chr (Char.code c lxor 0xff)) body
     in
     let* () =
       B.put ~key:backend_key ~data:(Bigstring.of_string scrambled) ()
     in
     (* The store found it on the way in; nothing here had to look. *)
     Corrupt.invalidate ();
     let* marks = listed () in
     check "a scrambled body is filed under its key"
       ~why:(fun () -> String.concat "," marks)
       (marks = [chunk_key]);

     let* detail = Corrupt.detail { Corruption.chunk_key; store = "local" } in
     check "the marker records what it hashed to instead"
       (match detail with
         | Some { Corruption_marker.computed = Some c; _ } ->
             c = Chunks.key_of_body (Bigstring.of_string scrambled)
             && c <> chunk_key
         | _ -> false);

     (* The chunk is in [known_chunks] from the first upload, so this is the
        case that fails if the marker is consulted after the session memo
        instead of before it. *)
     let* (_ : Manifest.t) = upload "b.bin" body in
     let* stored = B.get ~key:backend_key () in
     let stored = Bigstring.to_string stored in
     check "a marked chunk is re-uploaded, not deduped"
       ~why:(fun () ->
         Printf.sprintf "stored body hashes to %s"
           (Chunks.key_of_body (Bigstring.of_string stored)))
       (stored = body);

     let* marks = listed () in
     check "and the good write clears the marker" (marks = []);

     (* Nothing here ever deleted a marker: the store cleared it by re-verifying
        the object it took, which is the only thing that may. *)
     let+ report = Corrupt.list () in
     check "no marker survives as an empty shard"
       ~why:(fun () -> string_of_int (List.length report.Corruption.entries))
       (report.Corruption.entries = []));
  if checks () <> expected_checks then begin
    Printf.printf "only %d of %d checks ran\n" (checks ()) expected_checks;
    exit 1
  end;
  report ()
