(* A metadata operation completes from local state while the store cannot be
   reached, and what it owes the store is published once the link is back.

   Counted rather than timed: an operation that made no round trip cannot have
   waited on one, however fast or slow the machine running this. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "meta_offline"

module Real = (val Fixture.local_store (Filename.concat root "store"))
module Link = Doubles.Outage (Real)

module C =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Link : Backend_lwt.Store)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf_lwt.S)

module F = File_lwt.Make (C)
module Sq = Sync_lwt.Sync_queue.Make (C) (F)
module Mq = Sync_lwt.Meta_queue.Make (C) (F)
module W = Wal_lwt.Make (C)
module Js = File_store_lwt.Make (C)
module Lk = Logical_key.Make (C)
module Ck = Checkout_lwt.Make (C)

let settle () = Durable_queue_lwt.settle_all ~timeout:10. ()

let owed () =
  let+ records = W.list () in
  List.length records

let write rel content =
  let key = Lk.file rel in
  let* () = F.create key in
  let* (_ : int) = F.write key (Bigstring.of_string content) ~offset:0L in
  F.close key

(* Polled rather than awaited, so an operation that does wait on the store is a
   line in the snapshot instead of a run that never ends. *)
let offline what op =
  Link.reset ();
  let p = op () in
  let rec poll tries =
    if Lwt.state p <> Lwt.Sleep || tries = 0 then Lwt.return_unit
    else
      let* () = Lwt_unix.sleep 0.05 in
      poll (tries - 1)
  in
  let* () = poll 60 in
  let* owed = owed () in
  let outcome =
    match Lwt.state p with
      | Lwt.Return () -> "returned"
      | Lwt.Fail exn -> "failed: " ^ Printexc.to_string exn
      | Lwt.Sleep -> "waited on the store"
  in
  step "%s: %s, %d round trip(s), %d owed" what outcome (Link.calls ()) owed;
  Lwt.return (p, Link.calls ())

let show_tree () =
  let+ listed = F.list_tree ~prefix:Lk.root in
  List.iter
    (fun (e : Checkout.listed) ->
      step "local %s" (Logical_key.path e.Checkout.key))
    (List.sort
       (fun (a : Checkout.listed) (b : Checkout.listed) ->
         compare
           (Logical_key.path a.Checkout.key)
           (Logical_key.path b.Checkout.key))
       listed)

(* Ids are minted at random; the snapshot names them by order of first sight. *)
let ids : (string, string) Hashtbl.t = Hashtbl.create 8

let name_ids json =
  let rec go = function
    | `Assoc fields ->
        `Assoc
          (List.map
             (function
               | "id", `String id ->
                   let named =
                     match Hashtbl.find_opt ids id with
                       | Some named -> named
                       | None ->
                           let named =
                             Printf.sprintf "<folder-%d>"
                               (Hashtbl.length ids + 1)
                           in
                           Hashtbl.replace ids id named;
                           named
                   in
                   ("id", `String named)
               | k, v -> (k, go v))
             fields)
    | other -> other
  in
  go json

(* Ops only: an entry's key carries the time it was minted. *)
let show_journal () =
  let* keys = Js.list_journal_keys () in
  Lwt_list.iter_s
    (fun key ->
      let+ ops = Js.get_journal_entry key in
      Option.iter
        (List.iter (fun op ->
             step "journal %s"
               (Yojson.Basic.to_string (name_ids (Journal.to_json op)))))
        ops)
    keys

let () =
  Lwt_main.run
    (let* () = Ck.ensure_root () in
     Sq.start ~on_upload_done:(fun ~key:_ -> Lwt.return_unit);
     Mq.start ();

     case "set up while the link is up";
     let* () = F.mkdir (Lk.dir "docs") in
     let* () = F.mkdir (Lk.dir "scratch") in
     let* () = write "docs/a.txt" "alpha" in
     let* () = write "b.txt" "bravo" in
     let* () = settle () in
     (* Published now rather than by its debounce timer, which would otherwise
        fire during the outage and be counted against whichever operation it
        landed beside. *)
     let* () = Js.flush_cursor () in
     let* n = owed () in
     check "nothing is owed before the outage" (n = 0);

     (* The queues are held so that only the operation itself can be counted:
        a worker draining the previous one would reach the store too. *)
     case "the link goes down";
     Mq.set_paused true;
     Sq.set_paused true;
     Link.set_up false;
     let* _, calls =
       offline "rename b.txt -> c.txt" (fun () ->
           F.rename ~src:(Lk.file "b.txt") ~dst:(Lk.file "c.txt"))
     in
     check "a file rename makes no round trip" (calls = 0);
     let* _, calls =
       offline "delete c.txt" (fun () -> F.delete (Lk.file "c.txt"))
     in
     check "a delete makes no round trip" (calls = 0);
     let* _, calls =
       offline "rename docs -> papers" (fun () ->
           F.rename ~src:(Lk.dir "docs") ~dst:(Lk.dir "papers"))
     in
     check "a folder rename makes no round trip" (calls = 0);
     let* _, calls =
       offline "rmdir scratch" (fun () -> F.rmdir (Lk.dir "scratch"))
     in
     check "a folder removal makes no round trip" (calls = 0);
     let* n = owed () in
     check "each operation is owed" (n = 4);
     let* () = show_tree () in

     (* Last, because it holds the metadata lock until the link returns: a new
        folder's id is still claimed from the store when it is created. *)
     let* fresh, _ =
       offline "mkdir fresh" (fun () -> F.mkdir (Lk.dir "fresh"))
     in

     case "the link comes back";
     Link.set_up true;
     let* () = fresh in
     Mq.set_paused false;
     Sq.set_paused false;
     let* () = settle () in
     let* n = owed () in
     check "everything owed was published" (n = 0);
     let* () = show_tree () in
     let* () = show_journal () in
     report ~expected:7 ();
     Lwt.return_unit)
