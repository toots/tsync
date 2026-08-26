(* What the menu bar reads while the queue works through a backlog: which files
   a worker is on, and how many bytes are still owed. Bytes count whole files, so
   one in flight still owes all of itself until it lands. *)

open Lwt.Syntax

let root = "/tmp/tsync-queue-bytes-test"
let store_dir = root ^ "/store"

module C =
  (val Fixture.conf ~max_uploads:2 ~max_downloads:2
         ~store:(Fixture.local_store store_dir)
         ~root ()
      : Conf_lwt.S)

module F = File_lwt.Make (C)
module J = Journal.Make (C)
module W = Wal_lwt.Make (C)

let gate, open_gate = Lwt.wait ()
let dir_gate, open_dir_gate = Lwt.wait ()
let renaming = ref false

(* The file operations, with sending stubbed: what varies here is the
   queue's behaviour, not what an upload does. *)
module Sent = struct
  include F

  let upload ?cancel:_ _ = if !renaming then dir_gate else gate
end

module Sq = Sync_lwt.Sync_queue.Make (C) (Sent)

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

(* Every upload parks here, so the two a worker holds stay in flight for as long
   as the test needs them to. *)

(* A second gate, so the folder rename can be held in flight after the files
   have drained and the report can be read for what the queue calls it. *)

(* What a file operation does: the record is written, and then handed to
   whoever sends it. *)

let owe r =
  let entry_key = J.entry_key () in
  let* () = W.write entry_key r in
  Wal_lwt.Owed.signal W.owed (entry_key, r)

let post n size =
  let name = Printf.sprintf "f%d.txt" n in
  owe
    {
      Wal.ops = [`Put (name, Int64.of_int size)];
      state = Wal.Prepared;
      attempts = 0;
      last_error = None;
    }

(* Each name carries what the queue calls it, file or folder: the kind is what a
   peer replays the entry as, and the spelling no longer says which. Sorted,
   because [uploading] reports a set and the workers' order within it is not
   something to pin down. *)
let describe k =
  Printf.sprintf "%s(%s)" (Logical_key.to_string k)
    (match Logical_key.kind k with `File -> "file" | `Dir -> "dir")

let report label =
  Printf.printf "%-22s pending=%d uploading=[%s] bytes=%Ld\n" label
    (Sq.pending ())
    (String.concat " "
       (List.sort compare (List.map describe (Sq.uploading ()))))
    (Sq.pending_bytes ())

(* A folder rename: the op says the key names a directory and the queue has to
   say so too, or the entry it publishes is one a peer replays as a file. *)
let post_dir_rename () =
  owe
    {
      Wal.ops =
        [
          `Rename
            {
              Journal.dst = "photos";
              src = "pics";
              size = None;
              is_dir = true;
              id = Some "folder-id";
            };
        ];
      state = Wal.Prepared;
      attempts = 0;
      last_error = None;
    }

let () =
  Lwt_main.run
    (let* () = Io_lwt.Fs.rm_rf root in
     Sq.start ~on_upload_done:(fun ~key:_ -> Lwt.return_unit);

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

     renaming := true;
     let* () = post_dir_rename () in
     let* () = settle () in
     report "folder in flight";
     Lwt.wakeup_later open_dir_gate ();

     let* () = Sq.drain () in
     report "after drain";
     Lwt.return_unit)
