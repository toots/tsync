(* A directory rename moves one marker on the store, and either does so or
   does nothing at all.

   What went wrong on 2026-09-03 was neither: the new marker landed and the old
   one stayed, silently, so one folder id had two parents. Two silences did it,
   a parent this client held no id for (no key to delete, so no delete) and a
   delete that found nothing and said nothing. Both are failures now, and a
   failure leaves the local mirror where it was. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "rename"

module Store =
  (val Backend_lwt.make ~backend_type:"local"
         ~get_field:(fun _ -> Some (Filename.concat root "store"))
         ())

(* A delete that answers "nothing was there" for one key: what a store looks
   like from a client whose idea of the marker's key is wrong. *)
let silent = ref (Stored_key.listed "")

module Flaky : Backend_lwt.Store = struct
  include Store

  let delete ~key () =
    if key = !silent then Lwt.return false else Store.delete ~key ()
end

module C =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Flaky : Backend_lwt.Store)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf_lwt.S)

module F = File_lwt.Make (C)
module Lk = Logical_key.Make (C)
module Ck = Checkout_lwt.Make (C)

let ns id = C.domain_prefix ^ id ^ "/"

(* The folder markers under one namespace, by name. *)
let markers id =
  let* entries = Store.list_prefix ~prefix:(ns id) () in
  let+ bodies =
    Lwt_list.filter_map_s
      (fun (e : Backend.file_entry) ->
        if Stored_key.is_dir_key e.Backend.key then Lwt.return_none
        else
          let+ body = Store.get ~key:e.Backend.key () in
          Option.map
            (fun (m : Folder.marker) -> (m.Folder.name, m.Folder.id))
            (Folder.marker_of_string (Bigstring.to_string body)))
      entries
  in
  List.sort compare bodies

(* Ids are minted at random; the snapshot names them by order of first sight. *)
let aliases : (string, string) Hashtbl.t = Hashtbl.create 4

let alias id =
  match Hashtbl.find_opt aliases id with
    | Some a -> a
    | None ->
        let a = Printf.sprintf "<folder-%d>" (Hashtbl.length aliases + 1) in
        Hashtbl.replace aliases id a;
        a

let show_markers label id =
  let+ ms = markers id in
  step "%s: %s" label
    (String.concat ", " (List.map (fun (n, i) -> n ^ "=" ^ alias i) ms));
  ms

let local_dirs () =
  let+ _, dirs = Ck.list_children ~prefix:Lk.root () in
  List.sort compare dirs

let attempt what f =
  Lwt.catch
    (fun () ->
      let+ () = f () in
      step "%s: succeeded" what;
      true)
    (fun exn ->
      step "%s: refused (%s)" what (Printexc.to_string exn);
      Lwt.return false)

let marker_path rel =
  Filename.concat
    (Cache_layout.manifest_path ~cache_root:root ~domain_name:C.domain_name
       (Lk.dir rel))
    Stored_key.folder_marker_leaf

let () =
  Lwt_main.run
    (let* () = Ck.ensure_root () in
     case "a rename moves the marker and nothing else";
     let* () = F.mkdir (Lk.dir "d") in
     let* before = show_markers "root before" Stored_key.root_id in
     let id = List.assoc "d" before in
     let* ok =
       attempt "rename d -> d2" (fun () ->
           F.rename ~src:(Lk.dir "d") ~dst:(Lk.dir "d2"))
     in
     let* after = show_markers "root after" Stored_key.root_id in
     check "it went through" ok;
     check "one marker, under the new name, same id" (after = [("d2", id)]);
     let* dirs = local_dirs () in
     check "the mirror agrees" (dirs = ["d2"]);

     case "a delete that removes nothing is a rename that did not happen";
     silent :=
       Stored_key.child_key ~prefix:C.domain_prefix
         ~folder_id:Stored_key.root_id "d2";
     let* ok =
       attempt "rename d2 -> d3" (fun () ->
           F.rename ~src:(Lk.dir "d2") ~dst:(Lk.dir "d3"))
     in
     let* after = show_markers "root after" Stored_key.root_id in
     check "it was refused" (not ok);
     check "the store holds one marker, under the old name"
       (after = [("d2", id)]);
     let* dirs = local_dirs () in
     check "and the mirror is back where it was" (dirs = ["d2"]);
     silent := Stored_key.listed "";

     case "a parent this client holds no id for is not renamed from";
     (* A folder materialised by a peer's put, with a marker of its own but
        none for the directory above it: the shape [adopt_ancestor_ids] exists
        to repair, and the one that turned a delete into a no-op. *)
     let* () = F.mkdir (Lk.dir "p") in
     let* () = F.mkdir (Lk.dir "p/child") in
     let* () = Io_lwt.Fs.unlink_quiet (marker_path "p") in
     let* ok =
       attempt "rename p/child -> orphan" (fun () ->
           F.rename ~src:(Lk.dir "p/child") ~dst:(Lk.dir "orphan"))
     in
     check "it was refused" (not ok);
     let* dirs = local_dirs () in
     check "and nothing moved locally" (dirs = ["d2"; "p"]);
     let* _, under_p = Ck.list_children ~prefix:(Lk.dir "p") () in
     check "the child is still where it was" (under_p = ["child"]);

     case "a folder retired without its marker is not retired";
     silent :=
       Stored_key.child_key ~prefix:C.domain_prefix
         ~folder_id:Stored_key.root_id "d2";
     let* ok = attempt "rmdir d2" (fun () -> F.rmdir (Lk.dir "d2")) in
     let* after = show_markers "root after" Stored_key.root_id in
     check "it was refused" (not ok);
     check "the marker is still there" (List.mem_assoc "d2" after);
     let* dirs = local_dirs () in
     check "and so is the directory" (List.mem "d2" dirs);

     report ~expected:12 ();
     Lwt.return_unit);
  Scratch.cleanup root
