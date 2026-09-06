(* What a walk of the store's folder tree finds wrong with its shape, and what
   a repair does about it.

   The store here is planted in the shape the Files domain had on 2026-09-03:
   one folder's children filed under two parents, no anchors anywhere, and a
   namespace no marker points at. Only a client can see any of it, so this is
   where it has to be seen. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "integrity-tree"

module Store =
  (val Backend_lwt.make ~backend_type:"local"
         ~get_field:(fun _ -> Some (Filename.concat root "store"))
         ())

module C =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Store : Backend_lwt.Store)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf_lwt.S)

module I = Integrity_lwt.Make (C)

let ns id = C.domain_prefix ^ id ^ "/"

let put id name body =
  Store.put
    ~key:(Stored_key.in_space ~prefix:(ns id) name)
    ~data:(Bigstring.of_string body) ()

let marker name id = Folder.marker_to_string { Folder.name; id }

let manifest_body name =
  Manifest.encode ~name ~size:0L ~chunk_size:4 ~mtime:0.
    ~h1:(String.make 16 'a') ~h2:(String.make 16 'b') ~symlink:None ~keys:[]

(* Ids are minted at random; the snapshot names them by order of first sight. *)
let aliases : (string, string) Hashtbl.t = Hashtbl.create 8

let alias id =
  match Hashtbl.find_opt aliases id with
    | Some a -> a
    | None ->
        let a = Printf.sprintf "<folder-%d>" (Hashtbl.length aliases + 1) in
        Hashtbl.replace aliases id a;
        a

let show (r : Integrity.tree_report) =
  List.iter
    (fun f ->
      let line = Integrity.describe_finding f in
      let line =
        Hashtbl.fold
          (fun id a acc -> Str.global_replace (Str.regexp_string id) a acc)
          aliases line
      in
      step "%s" line)
    r.Integrity.findings;
  step "orphans checked: %b" r.Integrity.orphans_checked

let kinds (r : Integrity.tree_report) =
  List.map
    (function
      | Integrity.Twice _ -> "twice"
      | Integrity.Disowned _ -> "disowned"
      | Integrity.Unanchored _ -> "unanchored"
      | Integrity.Orphan _ -> "orphan"
      | Integrity.Trashed_live _ -> "trashed-live")
    r.Integrity.findings
  |> List.sort compare

let () =
  Lwt_main.run
    (let archived = Stored_key.new_id () and backup = Stored_key.new_id () in
     let song = Stored_key.new_id () and orphan = Stored_key.new_id () in
     List.iter (fun id -> ignore (alias id)) [archived; backup; song; orphan];
     let* () = put Stored_key.root_id "archived" (marker "Archived" archived) in
     let* () = put Stored_key.root_id "backup" (marker "Backup" backup) in
     let* () = put archived "tetris" (marker "Tetris" song) in
     let* () = put backup "tetris" (marker "Tetris" song) in
     let* () = put song "chart" (manifest_body "chart.pdf") in
     let* () = put orphan "lost" (manifest_body "lost.pdf") in
     (* The 2026-08-21 shape as well: a folder trashed, then restored, whose
        trash entry never went. *)
     let* () =
       Store.put
         ~key:
           (Stored_key.under
              (Stored_key.trash_namespace ~prefix:C.domain_prefix)
              "t1")
         ~data:
           (Bigstring.of_string
              (Folder.trash_marker_to_string ~name:"Archived" ~id:archived
                 ~path:"Archived"))
         ()
     in

     case "a tree with no anchors: one folder at two paths, and an orphan";
     let* r = I.tree_report () in
     show r;
     check
       "the shared folder is found twice, the trash names a live one, the rest \
        unanchored"
       (kinds r
       = [
           "orphan";
           "trashed-live";
           "twice";
           "unanchored";
           "unanchored";
           "unanchored";
           "unanchored";
         ]);

     case "an anchor decides which path is the folder's";
     let* () =
       Store.put
         ~key:(Stored_key.anchor_key ~prefix:C.domain_prefix ~folder_id:song)
         ~data:
           (Bigstring.of_string
              (Folder.anchor_to_string
                 { Folder.parent = backup; name = "Tetris" }))
         ()
     in
     let* r = I.tree_report () in
     show r;
     check "the marker under the other parent is disowned"
       (kinds r
       = ["disowned"; "orphan"; "trashed-live"; "unanchored"; "unanchored"]);

     case "a repair removes the disowned marker and anchors the rest";
     let* t = I.repair_tree () in
     step "removed %d, anchored %d, left %d" t.Integrity.removed
       t.Integrity.anchored
       (List.length t.Integrity.left);
     check "the marker and the trash entry removed, two folders anchored"
       (t.Integrity.removed = 2 && t.Integrity.anchored = 2);
     let* r = I.tree_report () in
     show r;
     check "what is left is the orphan, which a repair does not touch"
       (kinds r = ["orphan"]);
     let* listed = Store.list_prefix ~prefix:(ns archived) () in
     check "the leftover marker is gone from the store"
       (not
          (List.exists
             (fun (e : Backend.file_entry) ->
               e.Backend.key
               = Stored_key.in_space ~prefix:(ns archived) "tetris")
             listed));

     report ~expected:5 ();
     Lwt.return_unit);
  Scratch.cleanup root
