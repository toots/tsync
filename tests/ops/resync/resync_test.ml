(* Which way a sync goes, and what the bookmark is allowed to say afterwards.

   The choice is the whole of it: apply the journal since the local mark, or
   clear the cache and walk the folder tree whole. Getting it wrong is not
   visible in a single run — a bookmark advanced past folders a failed walk
   never reached leaves their files arriving later as journal puts, into
   directories no id names. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "resync"

module Store =
  (val Backend_lwt.make ~backend_type:"local"
         ~get_field:(fun _ -> Some (Filename.concat root "store"))
         ())

(* One key that will not read, so a walk has something to fail on and the
   bookmark rule has something to decide about. A wrapper rather than a chmod:
   the suite must behave the same as root. *)
let broken = ref (Stored_key.listed "")

module Flaky : Backend_lwt.Store = struct
  include Store

  let refuse key =
    Lwt.fail (Backend.Backend_error ("cannot read " ^ Stored_key.to_string key))

  let get ~key () = if key = !broken then refuse key else Store.get ~key ()

  let get_opt ~key () =
    if key = !broken then refuse key else Store.get_opt ~key ()

  let get_many = None
end

module C =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Flaky : Backend_lwt.Store)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf.S)

module R = Resync.Make (C)
module Fs = File_store.Make (C)
module Lk = Logical_key.Make (C)

let ns id = C.domain_prefix ^ id ^ "/"

let put id name body =
  Store.put
    ~key:(Stored_key.in_space ~prefix:(ns id) name)
    ~data:(Bigstring.of_string body) ()

let manifest_body name =
  Manifest.encode ~name ~size:0L ~chunk_size:4 ~mtime:0.
    ~h1:(String.make 16 'a') ~h2:(String.make 16 'b') ~symlink:None ~keys:[]

(* Nothing listens, so a notify that fired is recorded rather than sent. *)
let notified = ref 0
let notify () = incr notified

let run ?(full = false) () =
  R.run ~full ~parallelism:2 ~notify:(fun () -> notify ()) ()

let describe = function
  | Resync.Full { manifests; failed; reason } ->
      Printf.sprintf "full(%d manifests, %d failed, %s)" manifests failed reason
  | Resync.Incremental { applied } -> Printf.sprintf "incremental(%d)" applied

let () =
  Lwt_main.run
    (case "a client with no bookmark rebuilds";
     let* () = put Stored_key.root_id "a" (manifest_body "a.txt") in
     (* An empty journal cannot carry a reader to now whatever the bookmark
        says, so one published entry is what makes an incremental pass
        reachable at all. *)
     let* (_ : Journal.Entry_key.t) =
       Fs.write_journal_entry [`Put ("a.txt", 0L)]
     in
     check "nothing is recorded yet" (Fs.read_last_sync_key () = None);
     let* outcome = run () in
     step "%s" (describe outcome);
     check "it rebuilt"
       (match outcome with Resync.Full _ -> true | _ -> false)
       ~why:(fun () -> describe outcome);
     check "saying why"
       (match outcome with
         | Resync.Full { reason; _ } -> reason = "no bookmark (first run)"
         | _ -> false);
     check "it found the manifest"
       (match outcome with
         | Resync.Full { manifests; failed; _ } -> manifests = 1 && failed = 0
         | _ -> false);
     check "and told the daemon once" (!notified = 1);

     case "a clean rebuild records how far it got";
     check "the bookmark is set" (Fs.read_last_sync_key () <> None);

     case "a client already caught up applies the journal instead";
     let* outcome = run () in
     step "%s" (describe outcome);
     check "it did not rebuild"
       (match outcome with Resync.Incremental _ -> true | _ -> false)
       ~why:(fun () -> describe outcome);
     check "and told the daemon nothing" (!notified = 1);

     case "--full rebuilds a client that had no need to";
     let* outcome = run ~full:true () in
     step "%s" (describe outcome);
     check "it rebuilt"
       (match outcome with Resync.Full _ -> true | _ -> false)
       ~why:(fun () -> describe outcome);
     check "saying the caller asked"
       (match outcome with
         | Resync.Full { reason; _ } -> reason = "--full flag"
         | _ -> false);

     case "a walk that did not reach everything leaves the bookmark alone";
     let before = Fs.read_last_sync_key () in
     let* () = put Stored_key.root_id "b" (manifest_body "b.txt") in
     broken := Stored_key.in_space ~prefix:(ns Stored_key.root_id) "b";
     let* outcome = run ~full:true () in
     step "%s" (describe outcome);
     check "the failure is counted"
       (match outcome with
         | Resync.Full { failed; _ } -> failed > 0
         | _ -> false)
       ~why:(fun () -> describe outcome);
     (* The mark staying put is the whole rule: a run that advanced it here
        would leave the folders this walk never reached to arrive later as
        journal puts, into directories no id names. *)
     check "and the bookmark did not move"
       (Fs.read_last_sync_key () = before)
       ~why:(fun () -> "a partial walk advanced the mark");

     report ~expected:12 ();
     Lwt.return_unit)
