(* The upload queue's pause switch: paused work is held, not dropped, and
   [drain] still runs to completion so a paused queue cannot wedge shutdown. *)

open Lwt.Syntax

let root = "/tmp/tsync-pause-test"
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

let uploaded = ref 0

(* Long enough for a worker to reach the backend and back on a local store. *)
let settle () = Lwt_unix.sleep 0.2

let post n =
  let name = Printf.sprintf "f%d.txt" n in
  Sq.post ~entry_key:(J.entry_key ())
    {
      Wal.ops = [`Put (name, 0L)];
      state = Wal.Prepared;
      attempts = 0;
      last_error = None;
    }

let report label =
  Printf.printf "%-28s paused=%-5b pending=%d uploaded=%d\n" label
    (Sq.paused ()) (Sq.pending ()) !uploaded

let () =
  Lwt_main.run
    (let* () = Fs_util.rm_rf root in
     Sq.start
       ~upload:(fun ~key:_ ~cancel:_ ->
         incr uploaded;
         Lwt.return_unit)
       ~on_cursor:(fun ~entry_key:_ -> ())
       ~on_upload_done:(fun ~key:_ -> Lwt.return_unit);

     Sq.set_paused true;
     let* () = post 1 in
     let* () = settle () in
     report "posted while paused";

     Sq.set_paused false;
     let* () = settle () in
     report "resumed";

     (* [drain] must win over [paused], or shutdown never finishes. *)
     Sq.set_paused true;
     let* () = post 2 in
     let* () = settle () in
     report "posted while paused again";
     let* () = Sq.drain () in
     report "after drain";
     Lwt.return_unit)
