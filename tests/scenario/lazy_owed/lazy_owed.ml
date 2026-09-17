(* A browsing client lists a folder by reading it from the store and pruning
   what the store does not hold, and what this client made there and has not
   published yet is exactly that. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "lazy_owed"

module Real = (val Fixture.local_store (Filename.concat root "store"))

module C =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Real : Backend_lwt.Store)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf_lwt.S)

module F = File_lwt.Make_over (Lazy_checkout_lwt) (C)
module Sq = Sync_lwt.Sync_queue.Make (C) (F)
module Mq = Sync_lwt.Meta_queue.Make (C) (F)
module Lk = Logical_key.Make (C)
module Ck = Lazy_checkout_lwt.Make (C)

let settle () = Durable_queue_lwt.settle_all ~timeout:10. ()

let listed rel =
  let+ _, dirs = F.list_children ~prefix:(Lk.dir rel) in
  List.sort compare (List.map fst dirs)

let () =
  Lwt_main.run
    (let* () = Ck.ensure_root () in
     Sq.start ~on_upload_done:(fun ~key:_ -> Lwt.return_unit);
     Mq.start ();
     let* () = F.mkdir (Lk.dir "album") in
     let* () = F.mkdir (Lk.dir "album/old") in
     let* () = settle () in

     case "a folder made here and not published yet";
     Mq.set_paused true;
     let* () = F.mkdir (Lk.dir "album/new") in
     let* () = F.rmdir (Lk.dir "album/old") in
     let* dirs = listed "album" in
     step "album lists: %s" (String.concat ", " dirs);
     check "survives a browse of its folder, and a removal is not listed back"
       (dirs = ["new"]);

     case "once it is published";
     Mq.set_paused false;
     let* () = settle () in
     let* dirs = listed "album" in
     step "album lists: %s" (String.concat ", " dirs);
     check "the browse reads the store again and agrees" (dirs = ["new"]);
     report ~expected:2 ();
     Lwt.return_unit)
