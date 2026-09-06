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

(* Batches lost to the link before one is answered, so a walk has a failure to
   retry that is nobody's refusal. A refused key still fails the batch whole, as
   a store's own batch would. *)
let lose = ref 0

module Flaky : Backend_lwt.Store = struct
  include Store

  let refuse key =
    Lwt.fail (Backend.Backend_error ("cannot read " ^ Stored_key.to_string key))

  let get ~key () = if key = !broken then refuse key else Store.get ~key ()

  let get_opt ~key () =
    if key = !broken then refuse key else Store.get_opt ~key ()

  let get_many =
    Some
      (fun ~entries () ->
        if !lose > 0 then begin
          decr lose;
          Lwt.fail (Retry.failed ~kind:Retry.Transient ~op:"get_many" "502")
        end
        else
          Lwt_list.map_s
            (fun (e : Backend.file_entry) ->
              let+ body = get_opt ~key:e.Backend.key () in
              (e.Backend.key, body))
            entries)
end

module C =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Flaky : Backend_lwt.Store)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf_lwt.S)

module R = Resync_lwt.Make (C)
module Fs = File_store_lwt.Make (C)
module Lk = Logical_key.Make (C)

let ns id = C.domain_prefix ^ id ^ "/"

let put id name body =
  Store.put
    ~key:(Stored_key.in_space ~prefix:(ns id) name)
    ~data:(Bigstring.of_string body) ()

let manifest_body name =
  Manifest.encode ~name ~size:0L ~chunk_size:4 ~mtime:0.
    ~h1:(String.make 16 'a') ~h2:(String.make 16 'b') ~symlink:None ~keys:[]

let run ?(full = false) () = R.run ~full ~parallelism:2 ()

(* The rebuild's own report: what the applied entries gained after [anchor]. *)
let head () = Applied_entries.head ~cache_root:root ~domain_name:C.domain_name

let reported ?since () =
  let+ page =
    Applied_entries.since ~cache_root:root ~domain_name:C.domain_name ?since
      ~limit:1000 ()
  in
  match page with
    | None -> failwith "the applied entries no longer reach the anchor"
    | Some page -> List.concat_map snd page.Applied_entries.entries

let show_op = function
  | `Put (k, size) -> Printf.sprintf "put %s %Ld" k size
  | `Delete k -> "delete " ^ k
  | `Mkdir (k, id) ->
      Printf.sprintf "mkdir %s %s" k (Option.value id ~default:"-")
  | `Rmdir (k, id) ->
      Printf.sprintf "rmdir %s %s" k (Option.value id ~default:"-")
  | `Rename { Journal.dst; src; _ } -> Printf.sprintf "rename %s -> %s" src dst

let show_ops ops =
  step "reported: %s" (String.concat ", " (List.map show_op ops))

(* Planted as the last walk would have left it, an hour old, so a sweep by
   mtime has something older than the cutoff to decide about. *)
let plant path body =
  Tsync_io.Fs.mkdir_p_sync (Filename.dirname path);
  let oc = open_out_bin path in
  output_string oc body;
  close_out oc;
  let old = Unix.gettimeofday () -. 3600. in
  Unix.utimes path old old

(* As the last walk would have left it, an hour old: a marker written by the
   run just before is inside the tolerance the sweep gives a coarse clock. *)
let age path =
  let old = Unix.gettimeofday () -. 3600. in
  Unix.utimes path old old

let mirror_path name =
  Tsync_cache_layout.Cache_layout.manifest_path ~cache_root:root
    ~domain_name:C.domain_name
    (Logical_key.file_in Lk.root name)

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
     let* before = head () in
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
     let* ops = reported ?since:before () in
     show_ops ops;
     check "and the file it found is on the applied entries"
       (List.mem (`Put ("a.txt", 0L)) ops);

     case "a clean rebuild records how far it got";
     check "the bookmark is set" (Fs.read_last_sync_key () <> None);

     case "a client already caught up applies the journal instead";
     let* before = head () in
     let* outcome = run () in
     step "%s" (describe outcome);
     check "it did not rebuild"
       (match outcome with Resync.Incremental _ -> true | _ -> false)
       ~why:(fun () -> describe outcome);
     let* ops = reported ?since:before () in
     check "and reported nothing" (ops = []);

     case "--full rebuilds a client that had no need to";
     let* before = head () in
     let* outcome = run ~full:true () in
     step "%s" (describe outcome);
     check "it rebuilt"
       (match outcome with Resync.Full _ -> true | _ -> false)
       ~why:(fun () -> describe outcome);
     check "saying the caller asked"
       (match outcome with
         | Resync.Full { reason; _ } -> reason = "--full flag"
         | _ -> false);
     let* ops = reported ?since:before () in
     check "and a file the store still has as it was reports nothing" (ops = []);

     case "a rebuild rewrites the mirror in place";
     let chunk =
       Filename.concat
         (Tsync_cache_layout.Cache_layout.chunks_dir ~cache_root:root
            C.domain_name)
         "held"
     in
     plant chunk "bytes";
     plant (mirror_path "gone.txt") (manifest_body "gone.txt");
     check "the mirror holds what the last walk left"
       (Sys.file_exists (mirror_path "a.txt"));
     let* before = head () in
     let* outcome = run ~full:true () in
     step "%s" (describe outcome);
     check "a chunk survives the rebuild" (Sys.file_exists chunk);
     check "a manifest the store no longer has is dropped"
       (not (Sys.file_exists (mirror_path "gone.txt")));
     check "and one it still has is kept"
       (Sys.file_exists (mirror_path "a.txt"));
     let* ops = reported ?since:before () in
     show_ops ops;
     check "the drop is reported" (ops = [`Delete "gone.txt"]);

     case "a rebuild is a delta on the applied entries, not a new log";
     let* page =
       Applied_entries.since ~cache_root:root ~domain_name:C.domain_name
         ?since:before ~limit:10 ()
     in
     check "an anchor from before the rebuild is still bridged" (page <> None);

     case "a folder that moved is reported once, where it now is";
     let marker id name = Folder.marker_to_string { Folder.name; id } in
     let dir_marker name =
       Filename.concat (Filename.dirname (mirror_path name)) name |> fun d ->
       Filename.concat d Stored_key.folder_marker_leaf
     in
     plant (dir_marker "old") (marker "X" "old");
     let* () = put Stored_key.root_id "d" (marker "X" "new") in
     let* before = head () in
     let* outcome = run ~full:true () in
     step "%s" (describe outcome);
     let* ops = reported ?since:before () in
     show_ops ops;
     check "arrived under its id at the new path, and left nowhere"
       (ops = [`Mkdir ("new", Some "X")]);
     check "the old path is gone from the mirror"
       (not (Sys.file_exists (dir_marker "old")));

     case "a folder recreated under its name is a new folder";
     let* () = put Stored_key.root_id "d" (marker "Y" "new") in
     let* before = head () in
     let* outcome = run ~full:true () in
     step "%s" (describe outcome);
     let* ops = reported ?since:before () in
     show_ops ops;
     check "the old id leaves and the new one arrives, in that order"
       (ops = [`Rmdir ("new", Some "X"); `Mkdir ("new", Some "Y")]);

     case "a folder the store no longer has is reported gone";
     let* (_ : bool) =
       Store.delete
         ~key:(Stored_key.in_space ~prefix:(ns Stored_key.root_id) "d")
         ()
     in
     age (dir_marker "new");
     let* before = head () in
     let* outcome = run ~full:true () in
     step "%s" (describe outcome);
     let* ops = reported ?since:before () in
     show_ops ops;
     check "under the id it had" (ops = [`Rmdir ("new", Some "Y")]);

     case "a batch the link lost is asked again, not given up on";
     let before = Fs.read_last_sync_key () in
     lose := 1;
     let* outcome = run ~full:true () in
     step "%s" (describe outcome);
     check "the walk reached everything"
       (match outcome with
         | Resync.Full { failed; manifests; _ } -> failed = 0 && manifests = 1
         | _ -> false)
       ~why:(fun () -> describe outcome);
     check "and the bookmark moved" (Fs.read_last_sync_key () <> before);
     lose := 2;
     let* outcome = run ~full:true () in
     step "%s" (describe outcome);
     check "lost twice, the folder is counted against the run"
       (match outcome with
         | Resync.Full { failed; _ } -> failed = 1
         | _ -> false)
       ~why:(fun () -> describe outcome);

     case "a walk that did not reach everything leaves the bookmark alone";
     plant (mirror_path "gone.txt") (manifest_body "gone.txt");
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
     check "nor was anything swept" (Sys.file_exists (mirror_path "gone.txt"));

     report ~expected:27 ();
     Lwt.return_unit)
