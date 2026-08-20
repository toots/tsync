(* A domain served by more than one frontend: only one process keeps it
   converging with the store, and the others are handed {!Domain_engine.Passive}.

   What has to hold is that passive means "not the one polling", not "not
   uploading". A passive process's file ops stay writable — a FUSE mount that is
   not its domain's first frontend still accepts writes — so it needs its own
   queue or it records bytes nobody will ever send, while metadata ops keep
   landing on the store. Nothing reports that: the loop that watches for a queue
   gone quiet is started by the very call being withheld. *)

open Lwt.Syntax

let root = Filename.temp_dir "tsync-passive" ""
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

module E = Domain_engine.Make (C)
module P = Domain_engine.Passive (E)

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
  ignore
    (Sys.command
       (Printf.sprintf "rm -rf %s && mkdir -p %s %s" root root backend_root));
  write_local src body;
  Lwt_main.run
    (let* () = P.start ~freshness:Domain_engine.Revalidates () in
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
     let+ head = B.head_opt ~key:bkey () in
     Printf.printf "manifest in the store: %b\n" (head <> None))
