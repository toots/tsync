(* What the menu bar reads while the queue works through a backlog: which files
   a worker is on, and how many bytes are still owed. Bytes count whole files, so
   one in flight still owes all of itself until it lands. *)

open Lwt.Syntax

let root = "/tmp/tsync-queue-bytes-test"
let store_dir = root ^ "/store"

module C : Conf.S = struct
  let versioning = false
  let client_name = "test"
  let domain_name = "testdom"
  let domain_prefix = "tsync/testdom/manifests/"
  let chunk_prefix = "tsync/testdom/chunks/"
  let versions_prefix = "tsync/testdom/versions/"
  let journal_prefix = "tsync/testdom/journal/"
  let cursor_key = "tsync/testdom/cursor"
  let shares_prefix = "tsync/shares/"
  let store = Local_backend.make ~root:store_dir
  let members = [Backend.member ~name:"local" store]
  let cache_root = root ^ "/cache"
  let data_dir = root ^ "/data"
  let socket_path = ""
  let max_uploads = 2
  let max_chunk_buffers = 2
  let max_downloads = 2
  let chunk_size = Some 8
  let cache_chunk_size = Some 8
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module Sq = Sync_queue.Make (C)
module J = Journal.Make (C)

(* Long enough for a worker to reach the backend and back on a local store. *)
let settle () = Lwt_unix.sleep 0.2

(* Every upload parks here, so the two a worker holds stay in flight for as long
   as the test needs them to. *)
let gate, open_gate = Lwt.wait ()

let post n size =
  let name = Printf.sprintf "f%d.txt" n in
  Sq.post ~entry_key:(J.entry_key ())
    {
      Wal.ops = [`Put (name, Int64.of_int size)];
      state = Wal.Prepared;
      attempts = 0;
      last_error = None;
    }

(* Sorted: [uploading] reports a set, and the workers' order within it is not
   something to pin down. *)
let report label =
  Printf.printf "%-22s pending=%d uploading=[%s] bytes=%Ld\n" label
    (Sq.pending ())
    (String.concat " " (List.sort compare (Sq.uploading ())))
    (Sq.pending_bytes ())

let () =
  Lwt_main.run
    (let* () = Fs_util.rm_rf root in
     Sq.start
       ~upload:(fun ~key:_ ~cancel:_ -> gate)
       ~on_cursor:(fun ~entry_key:_ -> ())
       ~on_upload_done:(fun ~key:_ -> Lwt.return_unit);

     report "empty";

     let* () = post 1 100 in
     let* () = post 2 200 in
     let* () = post 3 300 in
     let* () = post 4 400 in
     let* () = settle () in
     report "4 posted";

     Lwt.wakeup_later open_gate ();
     let* () = settle () in
     report "gate open";

     let* () = Sq.drain () in
     report "after drain";
     Lwt.return_unit)
