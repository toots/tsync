(* A read of bytes this client does not hold needs the store, and somebody is
   waiting on it: with the link gone it fails within its deadline rather than
   holding its caller, which for a FUSE read is a task the kernel cannot freeze
   and so a machine that cannot suspend. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "read_offline"

module Real = (val Fixture.local_store (Filename.concat root "store"))
module Link = Doubles.Outage (Real)

module C =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Link : Backend_lwt.Store)
         ~members:
           [
             Backend.member ~role:`Main ~backend_type:"s3" ~name:"main"
               (module Link : Backend_lwt.Store);
           ]
         ~cache_root:root ~data_dir:root ~root ()
      : Conf_lwt.S)

module F = File_lwt.Make (C)
module Sq = Sync_lwt.Sync_queue.Make (C) (F)
module Lk = Logical_key.Make (C)
module Ck = Checkout_lwt.Make (C)

let settle () = Durable_queue_lwt.settle_all ~timeout:10. ()
let content = "the quick brown fox"

let read key =
  let buf = Bigstring.create (String.length content) in
  let+ n = F.read key buf ~offset:0L in
  Bigstring.to_string (Bigarray.Array1.sub buf 0 n)

(* Polled rather than awaited, so a read that does wait on the store is a line
   in the snapshot instead of a run that never ends. *)
let outcome_within seconds p =
  let rec poll tries =
    if Lwt.state p <> Lwt.Sleep || tries = 0 then Lwt.return_unit
    else
      let* () = Lwt_unix.sleep 0.05 in
      poll (tries - 1)
  in
  let+ () = poll (int_of_float (seconds /. 0.05)) in
  match Lwt.state p with
    | Lwt.Return body -> "returned " ^ body
    | Lwt.Fail exn when Io_lwt.Clock.is_timeout exn -> "failed: timed out"
    | Lwt.Fail exn -> "failed: " ^ Printexc.to_string exn
    | Lwt.Sleep -> "still waiting on the store"

let () =
  Lwt_main.run
    (let* () = Ck.ensure_root () in
     Sq.start ~on_upload_done:(fun ~key:_ -> Lwt.return_unit);
     let key = Lk.file "f.txt" in
     let* () = F.create key in
     let* (_ : int) = F.write key (Bigstring.of_string content) ~offset:0L in
     let* () = F.close key in
     let* () = settle () in
     let* () = F.evict key in

     case "a read of bytes not held here, with the link down";
     Tsync_checkout.Chunk_cache.read_deadline := 0.3;
     Link.set_up false;
     Link.reset ();
     let reading = read key in
     let* outcome = outcome_within 2. reading in
     step "read: %s, %d round trip(s)" outcome (Link.calls ());
     check "it fails within its deadline" (outcome = "failed: timed out");

     case "the same read without a deadline to speak of";
     Tsync_checkout.Chunk_cache.read_deadline := 3600.;
     let waiting = read key in
     let* outcome = outcome_within 1. waiting in
     step "read: %s" outcome;
     check "is the one that holds its caller"
       (outcome = "still waiting on the store");

     case "the link comes back";
     Link.set_up true;
     let* body = waiting in
     check "the read that waited is answered" (body = content);
     let before = Link.calls () in
     let* body = read key in
     check "and the next one from what it fetched, asking the store nothing"
       (body = content && Link.calls () = before);
     report ~expected:4 ();
     Lwt.return_unit)
