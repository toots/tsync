(* The upload queue's pause switch: paused work is held, not dropped, and
   [drain] still runs to completion so a paused queue cannot wedge shutdown. *)

open Lwt.Syntax

let root = "/tmp/tsync-pause-test"
let store_dir = root ^ "/store"

module C =
  (val Fixture.conf ~max_uploads:2 ~max_downloads:2
         ~store:(Fixture.local_store store_dir)
         ~root ()
      : Conf.S)

module Sq = Sync_queue.Make (C)
module J = Journal.Make (C)

let uploaded = ref 0

(* Waits for the queue to stop moving rather than for a length of time: on a
   loaded CI runner 0.2s elapsed before the worker had dequeued, and the report
   read one item still pending. Pausing is part of what is under test, so this
   cannot wait for the queue to empty -- while paused it never does. *)
let settle () =
  let rec go ~stable ~last ~polls =
    if polls > 200 then Lwt.return_unit
      (* ~10s: a queue this stuck is the finding *)
    else (
      let now = (Sq.pending (), Sq.paused ()) in
      let stable = if now = last then stable + 1 else 0 in
      if stable >= 4 then Lwt.return_unit
      else
        let* () = Lwt_unix.sleep 0.05 in
        go ~stable ~last:now ~polls:(polls + 1))
  in
  go ~stable:0 ~last:(-1, false) ~polls:0

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
