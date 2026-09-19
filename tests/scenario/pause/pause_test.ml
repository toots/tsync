(* The upload queue's pause switch: paused work is held, not dropped, and
   [drain] still runs to completion so a paused queue cannot wedge shutdown. *)

open Lwt.Syntax

let root = Scratch.dir "pause"
let store_dir = root ^ "/store"

module C =
  (val Fixture.conf ~max_uploads:2 ~max_downloads:2
         ~store:(Fixture.local_store store_dir)
         ~root ()
      : Conf_lwt.S)

module F = File_lwt.Make (C)
module J = Journal.Make (C)
module W = Wal_lwt.Make (C)

let uploaded = ref 0

(* The file operations, with sending stubbed: what varies here is the
   queue's behaviour, not what an upload does. *)
module Sent = struct
  include F

  let upload ?cancel:_ _ =
    incr uploaded;
    Lwt.return_unit
end

module Sq = Sync_lwt.Sync_queue.Make (C) (Sent)

(* What a file operation does: the record is written, and then handed to
   whoever sends it. *)

let owe r =
  let entry_key = J.entry_key () in
  let* () = W.write entry_key r in
  Wal_lwt.Owed.signal W.owed (entry_key, r)

let post n =
  let name = Printf.sprintf "f%d.txt" n in
  owe
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
    (let* () = Io_lwt.Fs.rm_rf root in
     Sq.start ~on_upload_done:(fun ~key:_ -> Lwt.return_unit);

     Sq.set_paused true;
     let* () = post 1 in
     let* () = Until.held (fun () -> Sq.pending () = 1 && !uploaded = 0) in
     report "posted while paused";

     Sq.set_paused false;
     let* () = Until.reached (fun () -> Sq.pending () = 0) in
     report "resumed";

     (* [drain] must win over [paused], or shutdown never finishes. *)
     Sq.set_paused true;
     let* () = post 2 in
     let* () = Until.held (fun () -> Sq.pending () = 1 && !uploaded = 1) in
     report "posted while paused again";
     let* () = Sq.drain () in
     report "after drain";
     Lwt.return_unit)
