(* What a process presenting a domain owes, without the convergence half.

   Presenting is every frontend's half; converging runs in the launcher. So what
   {!Domain_engine.Domain.start} leaves out must be only the shared-state work,
   and everything a write depends on must survive the split:

   - the upload queue, or the process records bytes nobody will ever send while
     metadata ops keep landing on the store;
   - the cursor bump, which is what tells a peer to read the journal at all. An
     upload publishes its entry and owes one, and an entry no peer goes looking
     for is a file nobody else can see.

   Neither reports itself. The loop that watches for a queue gone quiet is
   started by the queue, and a cursor that never moves reads exactly like one
   nothing has changed under. *)

open Lwt.Syntax

let root = Filename.temp_dir "tsync-presenting" ""
let backend_root = Filename.concat root "backend"
let src = Filename.concat root "hello.txt"
let body = "passive frontends still upload\n"

module C = struct
  let versioning = false
  let client_name = "test"
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
  let max_uploads = 2
  let max_chunk_buffers = 2
  let max_downloads = 2
  let chunk_size = Some 64
  let cache_chunk_size = Some 64
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

(* Held as the narrow view a frontend gets, so anything the convergence half
   provides is out of reach here rather than merely unused. *)
module P : Domain_engine.Domain = Domain_engine.Make (C)

let write_local path content =
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc

(* No drain: a queue with nothing running it would settle only by never
   returning, and a test that hangs reports nothing. Pauses let whatever workers
   exist finish the one file. *)
let settle () =
  let rec go n =
    if n = 0 then Lwt.return_unit
    else
      let* () = Lwt_unix.sleep 0.02 in
      go (n - 1)
  in
  go 50

let () =
  (* Short enough to observe inside [settle]. The default would have this
     reporting "not flushed yet" whether or not the flusher was ever started. *)
  Domain_engine.set_cursor_flush_interval 0.05;
  ignore
    (Sys.command
       (Printf.sprintf "rm -rf %s && mkdir -p %s %s" root root backend_root));
  write_local src body;
  Lwt_main.run
    (let* () = P.start () in
     let key = C.domain_prefix ^ "hello.txt" in
     let* () = P.F.create key in
     let* () = P.F.write_whole key ~src_path:src in
     let* () = P.F.close key in
     let* () = settle () in
     List.iter
       (fun (name, v) ->
         Printf.printf "%s: %s\n" name (Yojson.Safe.to_string v))
       (P.stats_fields ());
     (* The bytes themselves, not just the counter: a queue that reported a file
        finished without the store holding it would read the same above. *)
     let module L = Layout.Inode.Make (C) in
     let* bkey = L.ensure_manifest_key key in
     let module B = (val C.store : Backend.S) in
     let* head = B.head_opt ~key:bkey () in
     Printf.printf "manifest in the store: %b\n" (head <> None);
     (* What a peer polls. The upload published a journal entry, and an entry
        the cursor does not point past is one no other client reads. *)
     let module Fs = File_store.Make (C) in
     let+ cursor = Fs.fetch_cursor () in
     Printf.printf "cursor published: %b\n" (cursor <> None))
