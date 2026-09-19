(* A metadata operation completes from local state while the store cannot be
   reached, and what it owes the store is published once the link is back.

   Counted rather than timed: an operation that made no round trip cannot have
   waited on one, however fast or slow the machine running this. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "meta_offline"

module Real = (val Fixture.local_store (Filename.concat root "store"))
module Shaky = Doubles.Flaky (Real)
module Link = Doubles.Outage (Shaky)

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
module Rp = Sync_lwt.Replay.Make (C) (F)
module Sp = Sync_lwt.Sync_poller.Make (C) (F)
module J = Journal.Make (C)

let settle () = Durable_queue_lwt.settle_all ~timeout:10. ()

let owed () =
  let+ records = W.list () in
  List.length records

let read_whole key content =
  let buf = Bigstring.create (String.length content) in
  let+ n = F.read key buf ~offset:0L in
  Bigstring.to_string (Bigarray.Array1.sub buf 0 n)

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

let until ready =
  let rec go tries =
    if ready () then Lwt.return_true
    else if tries = 0 then Lwt.return_false
    else
      let* () = Lwt_unix.sleep 0.02 in
      go (tries - 1)
  in
  go 250

let until_io ready =
  let rec go tries =
    let* now = ready () in
    if now then Lwt.return_true
    else if tries = 0 then Lwt.return_false
    else
      let* () = Lwt_unix.sleep 0.02 in
      go (tries - 1)
  in
  go 500

let nothing_owed () =
  let+ n = owed () in
  n = 0

(* The names the store files under the root, read past the link. *)
let root_markers () =
  let prefix = C.domain_prefix ^ Stored_key.root_id ^ "/" in
  let* entries = Real.list_prefix ~prefix () in
  let+ names =
    Lwt_list.filter_map_s
      (fun (e : Backend.file_entry) ->
        let+ body = Real.get_opt ~key:e.Backend.key () in
        Option.bind body (fun b ->
            Option.map
              (fun (m : Folder.marker) -> m.Folder.name)
              (Folder.marker_of_string (Bigstring.to_string b))))
      entries
  in
  List.sort compare names

let trash_count () =
  let+ trash =
    Real.list_prefix
      ~prefix:
        (Stored_key.to_string
           (Stored_key.trash_namespace ~prefix:C.domain_prefix))
      ()
  in
  List.length
    (List.filter
       (fun (e : Backend.file_entry) ->
         Stored_key.is_child_object e.Backend.key)
       trash)

let on_store ~folder_id leaf =
  let+ body =
    Real.get_opt
      ~key:(Stored_key.child_key ~prefix:C.domain_prefix ~folder_id leaf)
      ()
  in
  body <> None

(* Sorted: readdir order is the filesystem's, and a snapshot taking it is one
   that passes on the machine that recorded it. *)
let local_dirs () =
  let+ _, dirs = Ck.list_children ~prefix:Lk.root () in
  List.sort compare dirs

let lookup rel =
  Folder_ids_lwt.lookup_id ~cache_root:root ~domain_name:C.domain_name
    (Lk.dir rel)

let journal_keys () =
  let* keys = Js.list_journal_keys () in
  Lwt_list.fold_left_s
    (fun acc key ->
      let+ ops = Js.get_journal_entry key in
      acc @ List.concat_map Journal.keys_of_op (Option.value ~default:[] ops))
    [] keys

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

     (* A new folder's id is this client's own, so creating one waits on
        nothing, and neither does what happens to it before the store hears. *)
     let* _, calls =
       offline "mkdir fresh" (fun () -> F.mkdir (Lk.dir "fresh"))
     in
     let* fresh_id = lookup "fresh" in
     check "a new folder makes no round trip and has its id"
       (calls = 0 && fresh_id <> None);
     let* _, calls =
       offline "mkdir gone; rmdir gone" (fun () ->
           let* () = F.mkdir (Lk.dir "gone") in
           F.rmdir (Lk.dir "gone"))
     in
     check "a new folder removed makes no round trip" (calls = 0);
     let* _, calls =
       offline "mkdir moved; rename moved -> moved2" (fun () ->
           let* () = F.mkdir (Lk.dir "moved") in
           F.rename ~src:(Lk.dir "moved") ~dst:(Lk.dir "moved2"))
     in
     let* moved_id = lookup "moved2" in
     check "a new folder renamed makes no round trip" (calls = 0);
     let* (_ : unit Lwt.t * int) =
       offline "mkdir brief; rename brief -> brief2; rmdir brief2" (fun () ->
           let* () = F.mkdir (Lk.dir "brief") in
           let* () = F.rename ~src:(Lk.dir "brief") ~dst:(Lk.dir "brief2") in
           F.rmdir (Lk.dir "brief2"))
     in
     let* _, calls =
       offline "symlink link -> papers/a.txt" (fun () ->
           F.symlink ~target:"papers/a.txt" (Lk.file "link"))
     in
     check "a symlink makes no round trip" (calls = 0);

     case "the link comes back";
     Link.set_up true;
     Mq.set_paused false;
     Sq.set_paused false;
     let* () = settle () in
     let* n = owed () in
     check "everything owed was published" (n = 0);
     let* () = show_tree () in
     let* () = show_journal () in
     let* names = root_markers () in
     step "store: %s" (String.concat ", " names);
     check "a folder removed before the store heard of it is not filed there"
       (not (List.mem "gone" names));
     let* dirs = local_dirs () in
     check "nor brought back here" (not (List.mem "gone" dirs));
     let* keys = journal_keys () in
     let* trash =
       Real.list_prefix
         ~prefix:
           (Stored_key.to_string
              (Stored_key.trash_namespace ~prefix:C.domain_prefix))
         ()
     in
     let trashed =
       List.filter
         (fun (e : Backend.file_entry) ->
           Stored_key.is_child_object e.Backend.key)
         trash
     in
     step "trash entries: %d" (List.length trashed);
     check
       "and neither its removal nor a rename of one is published, nor trashed"
       ((not
           (List.exists (fun k -> List.mem k ["gone"; "brief"; "brief2"]) keys))
       && List.length trashed = 1);
     let* link =
       Real.get_opt
         ~key:
           (Stored_key.child_key ~prefix:C.domain_prefix
              ~folder_id:Stored_key.root_id "link")
         ()
     in
     check "the symlink is published, and its entry with it"
       (List.mem "link" keys
       && Option.fold ~none:false
            ~some:(fun b ->
              Tsync_manifest.Manifest.symlink
                (Tsync_manifest.Manifest.of_string (Bigstring.to_string b))
              = Some "papers/a.txt")
            link);
     let* still = lookup "moved2" in
     check
       "a folder renamed before the store heard of it is filed where it is, \
        under the id it was created with"
       (List.mem "moved2" names
       && (not (List.mem "moved" names))
       && still = moved_id);

     (* The claim is held on the wire, so the removal lands while the store is
        being asked for the name. *)
     case "a new folder removed while its creation is being published";
     let* () = Js.flush_cursor () in
     Link.set_up false;
     Link.reset ();
     let* trashed_before = trash_count () in
     let* () = F.mkdir (Lk.dir "race") in
     let* out = until (fun () -> Link.calls () > 0) in
     check "the claim is out" out;
     let* (_ : unit Lwt.t * int) =
       offline "rmdir race" (fun () -> F.rmdir (Lk.dir "race"))
     in
     Link.set_up true;
     let* () = settle () in
     let* dirs = local_dirs () in
     let* names = root_markers () in
     let* keys = journal_keys () in
     let* trashed = trash_count () in
     step "local: %s; store: %s" (String.concat ", " dirs)
       (String.concat ", " names);
     check "the folder did not come back, here or on the store"
       ((not (List.mem "race" dirs)) && not (List.mem "race" names));
     check "and its removal leaves one entry pair and one trash entry at most"
       (List.length (List.filter (( = ) "race") keys) <= 2
       && trashed - trashed_before <= 1);

     (* An upload publishes into its folder whether or not the folder's own
        creation has been, so it claims the name first: a peer applying the put
        adopts the folder from its marker. *)
     case "an upload claims a folder whose creation is still owed";
     Mq.set_paused true;
     let* () = F.mkdir (Lk.dir "early") in
     let* () = write "early/f.txt" "echo" in
     let* uploaded = until (fun () -> Sq.pending () = 0) in
     let* names = root_markers () in
     let* keys = journal_keys () in
     check "the upload went ahead" uploaded;
     check "and the folder is filed on the store before its mkdir is published"
       (List.mem "early" names
       && List.mem "early/f.txt" keys
       && not (List.mem "early" keys));
     Mq.set_paused false;
     let* () = settle () in
     let* keys = journal_keys () in
     check "which follows" (List.mem "early" keys);

     (* Both ops are queued before either drains, so the rename into the folder
        names it by a path it has left by the time it is published. *)
     case "a file renamed into a folder that moves before it is published";
     let* () = F.mkdir (Lk.dir "into") in
     let* () = write "loose.txt" "foxtrot" in
     let* () = settle () in
     Mq.set_paused true;
     let* () =
       F.rename ~src:(Lk.file "loose.txt") ~dst:(Lk.file "into/loose.txt")
     in
     let* () = F.rename ~src:(Lk.dir "into") ~dst:(Lk.dir "moved-on") in
     Mq.set_paused false;
     let* () = settle () in
     let* n = owed () in
     let* names = root_markers () in
     let* back = lookup "into" in
     let* moved_on = lookup "moved-on" in
     let* inside =
       Real.list_prefix
         ~prefix:(C.domain_prefix ^ Option.value moved_on ~default:"?" ^ "/")
         ()
     in
     let inside =
       List.filter
         (fun (e : Backend.file_entry) ->
           Stored_key.is_child_object e.Backend.key)
         inside
     in
     let* filed =
       on_store ~folder_id:(Option.value moved_on ~default:"?") "loose.txt"
     in
     let* left = on_store ~folder_id:Stored_key.root_id "loose.txt" in
     step "objects under moved-on: %d" (List.length inside);
     step "store: %s" (String.concat ", " names);
     check "both are published" (n = 0);
     check
       "the file is filed in the folder under its new name, and the old one is \
        not brought back"
       (List.mem "moved-on" names
       && (not (List.mem "into" names))
       && back = None
       && List.length inside = 1
       && filed && not left);

     (* The peer's manifest is held on the wire, so the local rename lands
        while the entry that wants it is still being applied. *)
     case "a peer's entry waiting on the store holds up no local operation";
     let* () = write "local.txt" "golf" in
     let* () = settle () in
     let* () = Js.flush_cursor () in
     Mq.set_paused true;
     Sq.set_paused true;
     Link.set_up false;
     Link.reset ();
     let applying = F.apply_foreign_ops [`Put ("theirs.txt", 5L)] in
     let* out = until (fun () -> Link.calls () > 0) in
     check "the peer's fetch is out" out;
     let* renamed, calls =
       offline "rename local.txt -> local2.txt" (fun () ->
           F.rename ~src:(Lk.file "local.txt") ~dst:(Lk.file "local2.txt"))
     in
     check "the local rename made no round trip, and did not wait"
       (calls = 0 && Lwt.state renamed = Lwt.Return ());
     Link.set_up true;
     let* () = applying in
     Mq.set_paused false;
     Sq.set_paused false;
     let* () = settle () in

     (* Every other folder here sits at the root, whose id is fixed: these are
        published once their parent is gone locally, which is what a recursive
        removal leaves behind it. *)
     case "a folder removed with everything under it";
     let* () = F.mkdir (Lk.dir "tree") in
     let* () = F.mkdir (Lk.dir "tree/sub") in
     let* () = write "tree/sub/leaf.txt" "hotel" in
     let* () = settle () in
     let* sub_id = lookup "tree/sub" in
     Mq.set_paused true;
     let* () = F.delete (Lk.file "tree/sub/leaf.txt") in
     let* () = F.rmdir (Lk.dir "tree/sub") in
     let* () = F.rmdir (Lk.dir "tree") in
     Mq.set_paused false;
     let* published = until_io nothing_owed in
     let* leaf =
       Real.get_opt
         ~key:
           (Stored_key.child_key ~prefix:C.domain_prefix
              ~folder_id:(Option.value sub_id ~default:"?")
              "leaf.txt")
         ()
     in
     let* names = root_markers () in
     check "each removal is published, none parked"
       (published && not (Mq.degraded ()));
     check "the file is gone from the store, and the folder from the root"
       (leaf = None && not (List.mem "tree" names));

     (* The peer names the folder by the path this client moved it from, and
        whether that is still the same folder is the store's to say. *)
     case "a peer's entry under a folder moved here holds up no local operation";
     let* () = F.mkdir (Lk.dir "there") in
     let* () = write "there/x.txt" "india" in
     let* () = settle () in
     let* () = Js.flush_cursor () in
     Mq.set_paused true;
     Sq.set_paused true;
     let* () = F.rename ~src:(Lk.dir "there") ~dst:(Lk.dir "here") in
     Link.set_up false;
     Link.reset ();
     let applying = F.apply_foreign_ops [`Delete "there/x.txt"] in
     let* out = until (fun () -> Link.calls () > 0) in
     check "the peer's read is out" out;
     let* made, calls =
       offline "mkdir meanwhile" (fun () -> F.mkdir (Lk.dir "meanwhile"))
     in
     check "the local mkdir made no round trip, and did not wait"
       (calls = 0 && Lwt.state made = Lwt.Return ());
     Link.set_up true;
     let* () = applying in
     let* gone = F.stat (Lk.file "here/x.txt") in
     check "and the peer's delete reached the file where it is now" (gone = None);
     Mq.set_paused false;
     Sq.set_paused false;
     let* () = settle () in

     (* What a crash leaves is the intent, written before anything moved, and
        no telling how far the local half got. *)
     case "an operation a crash interrupted is finished on the next start";
     let* () = F.mkdir (Lk.dir "halfway") in
     let* () = settle () in
     let* halfway = lookup "halfway" in
     let* () = W.record (J.entry_key ()) [`Mkdir ("begun", Some "begun-id")] in
     let* () = W.record (J.entry_key ()) [`Rmdir ("halfway", halfway)] in
     let* () = Ck.delete_dir (Lk.dir "halfway") in
     let* () = Rp.reconcile () in
     let* published = until_io nothing_owed in
     let* begun = lookup "begun" in
     let* dirs = local_dirs () in
     let* names = root_markers () in
     let* keys = journal_keys () in
     let entries_for name = List.length (List.filter (( = ) name) keys) in
     check "one that never started happens here and on the store, once"
       (published && begun = Some "begun-id" && List.mem "begun" names
       && entries_for "begun" = 1);
     check "one whose local half was done is not done twice, and is published"
       ((not (List.mem "halfway" dirs)) && not (List.mem "halfway" names));

     (* A peer removed the file on the store, this client renamed it and then
        removed it: the rename has nothing to move and nothing to publish in
        its place, and must not sit at the head of the queue for good. *)
     case "a rename with nothing left to move, here or on the store";
     let* () = write "moot.txt" "juliet" in
     let* () = settle () in
     Mq.set_paused true;
     let* () = F.rename ~src:(Lk.file "moot.txt") ~dst:(Lk.file "moot2.txt") in
     let* () = F.delete (Lk.file "moot2.txt") in
     let* () = F.mkdir (Lk.dir "behind") in
     let* (_ : bool) =
       Real.delete
         ~key:
           (Stored_key.child_key ~prefix:C.domain_prefix
              ~folder_id:Stored_key.root_id "moot.txt")
         ()
     in
     Mq.set_paused false;
     let* published = until_io nothing_owed in
     let* names = root_markers () in
     check "it is owed nothing, and what follows it is published"
       (published && List.mem "behind" names && not (Mq.degraded ()));

     (* A request that comes back failed, where the outage above is one that
        waits: the queue retries, and what it retries must not be overtaken. *)
     case "a refused request lets no later operation overtake";
     let* () = F.mkdir (Lk.dir "build") in
     let* () = settle () in
     Mq.set_paused true;
     let* () = F.rmdir (Lk.dir "build") in
     let* () = F.mkdir (Lk.dir "build") in
     Shaky.refuse_next 1;
     Mq.set_paused false;
     let* published = until_io nothing_owed in
     let* dirs = local_dirs () in
     let* names = root_markers () in
     check "both are published" (published && Shaky.refusals () = 1);
     check "and the new folder did not meet the old one's name still taken"
       (List.mem "build" dirs && List.mem "build" names
       && not
            (List.exists
               (fun d -> d <> "build" && String.starts_with ~prefix:"build" d)
               (dirs @ names)));

     case "a claim the link refused is made again";
     Mq.set_paused true;
     let* () = F.mkdir (Lk.dir "claimed") in
     Shaky.refuse_next ~on:"put_if_absent" 1;
     Mq.set_paused false;
     let* published = until_io nothing_owed in
     let* names = root_markers () in
     check "the folder is filed on the store"
       (published && List.mem "claimed" names);

     case "an operation the store refuses for good steps aside";
     Mq.set_paused true;
     let* () = F.mkdir (Lk.dir "stuck") in
     let* () = F.mkdir (Lk.dir "after") in
     Shaky.refuse_next ~with_:Backend.Not_writable 1;
     Mq.set_paused false;
     (* A publish files its marker and then drops its record, so "after" on the
        store and "after" no longer owed are two moments: both are waited for,
        or the count taken between them still holds the one that just landed. *)
     let* passed =
       until_io (fun () ->
           let* names = root_markers () in
           let+ n = owed () in
           List.mem "after" names && n = 1)
     in
     let* n = owed () in
     let* names = root_markers () in
     check "what follows it is published" passed;
     check "it stays owed, and is reported"
       ~why:(fun () ->
         Printf.sprintf "owed=%d degraded=%b stuck filed=%b" n (Mq.degraded ())
           (List.mem "stuck" names))
       (n = 1 && Mq.degraded () && not (List.mem "stuck" names));
     let* () = Mq.rearm () in
     let* published = until_io nothing_owed in
     let* names = root_markers () in
     check "the retry sweep lands it, and the report clears"
       (published && List.mem "stuck" names && not (Mq.degraded ()));

     (* Not the link and not the store: a failure of this client's own, which
        waiting does not clear, and which at the head of a queue that keeps its
        order would hold every later operation for as long as it kept failing. *)
     case "an operation that fails on this client's own account steps aside";
     let* () = write "after.txt" "kilo" in
     let* () = settle () in
     Mq.set_paused true;
     let* () = F.mkdir (Lk.dir "faulty") in
     let* () =
       F.rename ~src:(Lk.file "after.txt") ~dst:(Lk.file "after2.txt")
     in
     Shaky.refuse_next ~on:"put_if_absent" ~with_:(Invalid_argument "a bug")
       1000;
     Mq.set_paused false;
     let* passed =
       until_io (fun () -> on_store ~folder_id:Stored_key.root_id "after2.txt")
     in
     check "what follows it is published, and it is reported"
       (passed && Mq.degraded ());
     Shaky.refuse_next 0;
     let* () = Mq.rearm () in
     let* published = until_io nothing_owed in
     let* names = root_markers () in
     check "and it lands once it can"
       (published && List.mem "faulty" names && not (Mq.degraded ()));

     (* Entries are applied in order, so one that fails here on this client's
        own account would keep every later one from it: a peer's folder under
        a name a file of this client's holds cannot be made, however often it
        is tried. *)
     case "a peer's entry that cannot be applied here steps aside";
     let* () = write "inway" "lima" in
     let* () = settle () in
     let from_peer ops =
       let mine = Journal.Entry_key.to_string (J.entry_key ()) in
       let theirs =
         String.sub mine 0 (String.index mine '-' + 1) ^ String.make 32 'f'
       in
       let* () = Lwt_unix.sleep 0.003 in
       match Journal.Entry_key.of_string theirs with
         | None -> Lwt.fail_with ("not an entry key: " ^ theirs)
         (* Past this client's own journal writer, which would count the
            entry as one it made and so has nothing to apply. *)
         | Some entry_key ->
             let* () =
               Real.put
                 ~key:
                   (Stored_key.in_space ~prefix:C.journal_prefix
                      (Journal.Entry_key.relative_path entry_key))
                 ~data:(Bigstring.of_string (Journal.encode ops))
                 ()
             in
             (* The cursor too, which is what a peer bumps and what the poller
                waits on. *)
             Real.put ~key:C.cursor_key
               ~data:
                 (Bigstring.of_string (Journal.Entry_key.to_string entry_key))
               ()
     in
     let* () = from_peer [`Mkdir ("inway/sub", Some "peer-sub")] in
     let* () = from_peer [`Mkdir ("fine", Some "peer-fine")] in
     let* applied = Rp.apply_foreign ~on_changed:ignore () in
     let* fine = lookup "fine" in
     step "applied %d, stepped aside %d" applied (List.length (Rp.unapplied ()));
     check "the entry after it is applied, and it is reported"
       (fine = Some "peer-fine" && List.length (Rp.unapplied ()) = 1);
     let* () = F.delete (Lk.file "inway") in
     let* () = Ck.create_dir (Lk.dir "inway") in
     let* applied = Rp.apply_foreign ~on_changed:ignore () in
     let* sub = lookup "inway/sub" in
     step "applied %d, stepped aside %d" applied (List.length (Rp.unapplied ()));
     check "and it lands on a later pass, once it can"
       (sub = Some "peer-sub" && Rp.unapplied () = []);
     let* () = settle () in

     (* The switch a frontend flips: it holds what would change the domain, in
        either direction, and nothing a reader is waiting on. The poller runs
        throughout, as it does in a daemon, and is told. *)
     case "while changes are held";
     let* () = write "held.txt" "mike" in
     let* () = settle () in
     let* () = Js.flush_cursor () in
     let held = ref true in
     Sp.start ~paused:(fun () -> !held) ~on_changed:ignore ();
     Mq.set_paused true;
     Sq.set_paused true;
     let* () = from_peer [`Mkdir ("theirs-held", Some "peer-held")] in
     let* () = F.mkdir (Lk.dir "ours-held") in
     let* () = F.rename ~src:(Lk.file "held.txt") ~dst:(Lk.file "held2.txt") in
     let* () = Lwt_unix.sleep 0.3 in
     let* names = root_markers () in
     let* owed = owed () in
     let* theirs = lookup "theirs-held" in
     check "nothing of ours reaches the store"
       (owed = 2 && not (List.mem "ours-held" names));
     check "and what a peer did is not applied here" (theirs = None);
     let* body = read_whole (Lk.file "held2.txt") "mike" in
     check "while a file read here is served" (body = "mike");

     case "and once they flow again";
     held := false;
     Mq.set_paused false;
     Sq.set_paused false;
     let* published = until_io nothing_owed in
     let* applied =
       until_io (fun () ->
           let+ theirs = lookup "theirs-held" in
           theirs = Some "peer-held")
     in
     let* names = root_markers () in
     check "ours is published, and theirs applied"
       (published && applied && List.mem "ours-held" names);

     report ~expected:48 ();
     Lwt.return_unit)
