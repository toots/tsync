(* An upload whose staged bytes are gone by the time it runs publishes nothing.
   Its record names a file that was never sent, and an entry for it would send
   every peer looking for something the store does not hold.

   The bytes are taken away here without cancelling the upload, which every path
   in the daemon is meant to do: what is under test is the queue's own answer
   when one of them forgets. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "upload-gone"

module C =
  (val Fixture.conf ~max_uploads:1 ~max_downloads:1
         ~store:(Fixture.local_store (Filename.concat root "store"))
         ~root ()
      : Conf_lwt.S)

module F = File_lwt.Make (C)
module Sq = Sync_lwt.Sync_queue.Make (C) (F)
module Mfs = Staged_lwt.Manifest.Make (C)
module W = Wal_lwt.Make (C)
module Js = File_store_lwt.Make (C)
module Lk = Logical_key.Make (C)

let write rel content =
  let key = Lk.file rel in
  let* () = F.create key in
  let* (_ : int) = F.write key (Bigstring.of_string content) ~offset:0L in
  F.close key

let () =
  Lwt_main.run
    (Sq.start ~on_upload_done:(fun ~key:_ -> Lwt.return_unit);
     case "an upload whose staged bytes went without it";
     Sq.set_paused true;
     let* () = write "gone.txt" "never sent" in
     let* owed = W.list () in
     check "is owed" (List.length owed = 1);
     let* () = Mfs.delete (Lk.file "gone.txt") in
     Sq.set_paused false;
     let* () = Durable_queue_lwt.settle_all ~timeout:10. () in
     let* entries = Js.list_journal_keys () in
     step "journal entries: %d" (List.length entries);
     check "publishes no entry" (entries = []);
     let* owed = W.list () in
     check "and is no longer owed" (owed = []);
     let module B = (val C.store : C.Store) in
     let* manifest =
       B.get_opt
         ~key:
           (Stored_key.child_key ~prefix:C.domain_prefix
              ~folder_id:Stored_key.root_id "gone.txt")
         ()
     in
     check "nor is a manifest for it on the store" (manifest = None);

     case "an upload with its bytes in place";
     let* () = write "kept.txt" "sent" in
     let* () = Durable_queue_lwt.settle_all ~timeout:10. () in
     let* entries = Js.list_journal_keys () in
     check "still publishes its entry" (List.length entries = 1);
     report ~expected:5 ();
     Lwt.return_unit);
  Scratch.cleanup root
