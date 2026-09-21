(* A directory rename moves one marker on the store, and either does so or
   does nothing at all.

   What went wrong on 2026-09-03 was neither: the new marker landed and the old
   one stayed, silently, so one folder id had two parents. Two silences did it,
   a parent this client held no id for (no key to delete, so no delete) and a
   delete that found nothing and said nothing. The first is a refusal now, and
   nothing moves. The second cannot silently split a folder any more: the
   folder's anchor is written with the new marker, before the old one goes, so
   whatever the delete left behind is a marker no reader believes. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "rename"

module Store = (val Fixture.local_store (Filename.concat root "store"))

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
module Mq = Sync_lwt.Meta_queue.Make (C) (F)
module Lk = Logical_key.Make (C)
module Ck = Checkout_lwt.Make (C)
module Tree = Inode_tree_lwt.Make (C)

let ns id = C.domain_prefix ^ id ^ "/"

let anchor_of id =
  let+ body =
    Store.get_opt
      ~key:(Stored_key.anchor_key ~prefix:C.domain_prefix ~folder_id:id)
      ()
  in
  Option.bind body (fun b -> Folder.anchor_of_string (Bigstring.to_string b))

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
  if id = Stored_key.root_id || id = Stored_key.trash_id then id
  else (
    match Hashtbl.find_opt aliases id with
      | Some a -> a
      | None ->
          let a = Printf.sprintf "<folder-%d>" (Hashtbl.length aliases + 1) in
          Hashtbl.replace aliases id a;
          a)

let show_anchor id =
  let+ a = anchor_of id in
  step "anchor of %s: %s" (alias id)
    (match a with
      | Some a ->
          Printf.sprintf "in %s as %s" (alias a.Folder.parent) a.Folder.name
      | None -> "none");
  a

let show_markers label id =
  let+ ms = markers id in
  step "%s: %s" label
    (String.concat ", " (List.map (fun (n, i) -> n ^ "=" ^ alias i) ms));
  ms

let local_dirs () =
  let+ _, dirs = Ck.list_children ~prefix:Lk.root () in
  List.sort compare dirs

(* A metadata operation returns once its local half is done; what the store
   holds is the queue's to publish, so every assertion about the store waits for
   it. *)
let settle () = Durable_queue_lwt.settle_all ~timeout:10. ()

let attempt ?(settled = true) what f =
  Lwt.catch
    (fun () ->
      let* () = f () in
      let+ () = if settled then settle () else Lwt.return_unit in
      step "%s: succeeded" what;
      true)
    (fun exn ->
      step "%s: refused (%s)" what (Printexc.to_string exn);
      Lwt.return false)

(* Where the id a path last named is kept, which a folder no op ever named
   here has none of. *)
let remembered_path rel =
  Filename.concat
    (Filename.concat
       (Cache_layout.folders_dir ~cache_root:root C.domain_name)
       "by-path")
    (Digest.to_hex (Digest.string (Logical_key.to_string (Lk.dir rel))))

let marker_path rel =
  Filename.concat
    (Cache_layout.manifest_path ~cache_root:root ~domain_name:C.domain_name
       (Lk.dir rel))
    Stored_key.folder_marker_leaf

let () =
  Lwt_main.run
    (let* () = Ck.ensure_root () in
     Mq.start ();
     case "a rename moves the marker and nothing else";
     let* () = F.mkdir (Lk.dir "d") in
     let* () = settle () in
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
     let* anchor = show_anchor id in
     check "and the anchor names the new place"
       (anchor = Some { Folder.parent = Stored_key.root_id; name = "d2" });

     case "a delete that removes nothing leaves a marker no reader believes";
     silent :=
       Stored_key.child_key ~prefix:C.domain_prefix
         ~folder_id:Stored_key.root_id "d2";
     let* ok =
       attempt "rename d2 -> d3" (fun () ->
           F.rename ~src:(Lk.dir "d2") ~dst:(Lk.dir "d3"))
     in
     let* after = show_markers "root after" Stored_key.root_id in
     check "it went through" ok;
     check "both markers are on the store" (after = [("d2", id); ("d3", id)]);
     let* anchor = show_anchor id in
     check "the anchor names the new one"
       (anchor = Some { Folder.parent = Stored_key.root_id; name = "d3" });
     let* listed = Tree.children ~folder_id:Stored_key.root_id () in
     let names =
       List.filter_map
         (function
           | { Inode_tree.body = Inode_tree.Dir m; _ } -> Some m.Folder.name
           | _ -> None)
         listed
       |> List.sort compare
     in
     step "the store lists: %s" (String.concat ", " names);
     check "and a reader sees the folder once, at the new name" (names = ["d3"]);
     silent := Stored_key.listed "";
     (* Back to one marker, so the cases below start clean. *)
     let* (_ : bool) =
       Store.delete
         ~key:
           (Stored_key.child_key ~prefix:C.domain_prefix
              ~folder_id:Stored_key.root_id "d2")
         ()
     in
     let* () = F.rename ~src:(Lk.dir "d3") ~dst:(Lk.dir "d2") in
     let* () = settle () in

     case "a parent this client holds no id for is not renamed from";
     (* A folder materialised by a peer's put, with a marker of its own but
        none for the directory above it: the shape [adopt_ancestor_ids] exists
        to repair, and the one that turned a delete into a no-op. *)
     let* () = F.mkdir (Lk.dir "p") in
     let* () = F.mkdir (Lk.dir "p/child") in
     let* () = settle () in
     let* () = Io_lwt.Fs.unlink_quiet (marker_path "p") in
     let* () = Io_lwt.Fs.unlink_quiet (remembered_path "p") in
     let* ok =
       attempt "rename p/child -> orphan" (fun () ->
           F.rename ~src:(Lk.dir "p/child") ~dst:(Lk.dir "orphan"))
     in
     check "it was refused" (not ok);
     let* dirs = local_dirs () in
     check "and nothing moved locally" (dirs = ["d2"; "p"]);
     let* _, under_p = Ck.list_children ~prefix:(Lk.dir "p") () in
     check "the child is still where it was" (under_p = ["child"]);

     case "a folder retired is anchored to the trash first";
     let* ok = attempt "rmdir d2" (fun () -> F.rmdir (Lk.dir "d2")) in
     let* after = show_markers "root after" Stored_key.root_id in
     check "it went through" ok;
     check "the marker is gone from the root" (not (List.mem_assoc "d2" after));
     let* anchor = show_anchor id in
     check "and the anchor names the trash"
       (anchor = Some { Folder.parent = Stored_key.trash_id; name = "d2" });

     case "a peer's rename onto a folder of ours moves ours aside";
     let* () = F.mkdir (Lk.dir "x") in
     let* () = F.mkdir (Lk.dir "y") in
     let* () = settle () in
     let* before = show_markers "root before" Stored_key.root_id in
     let peers = List.assoc "x" before and ours = List.assoc "y" before in
     (* What the peer's own rename left on the store: its folder filed under y,
        over ours. *)
     let* () =
       Store.put
         ~key:
           (Stored_key.child_key ~prefix:C.domain_prefix
              ~folder_id:Stored_key.root_id "y")
         ~data:
           (Bigstring.of_string
              (Folder.marker_to_string { Folder.name = "y"; id = peers }))
         ()
     in
     let* ok =
       attempt "apply the peer's rename x -> y" (fun () ->
           F.apply_foreign_ops
             [
               `Rename
                 Journal.
                   {
                     src = "x";
                     dst = "y";
                     size = None;
                     is_dir = true;
                     id = Some peers;
                   };
             ])
     in
     let* dirs = local_dirs () in
     step "local: %s" (String.concat ", " dirs);
     let* after = show_markers "root after" Stored_key.root_id in
     check "it applied" ok;
     check "the peer's folder has the name"
       (List.assoc_opt "y" after = Some peers);
     check "ours is published under a name of its own"
       (List.exists (fun (name, id) -> id = ours && name <> "y") after);

     case "a second conflict on one name finds a name of its own";
     (* Local y is the peer's folder now, and its conflicted copy is taken: a
        third folder moved onto y has to set the peer's aside under a name
        neither holds. *)
     let* () = F.mkdir (Lk.dir "w") in
     let* () = settle () in
     let* markers = show_markers "root before" Stored_key.root_id in
     let third = List.assoc "w" markers in
     let* () =
       Store.put
         ~key:
           (Stored_key.child_key ~prefix:C.domain_prefix
              ~folder_id:Stored_key.root_id "y")
         ~data:
           (Bigstring.of_string
              (Folder.marker_to_string { Folder.name = "y"; id = third }))
         ()
     in
     let* ok =
       attempt "apply the peer's rename w -> y" (fun () ->
           F.apply_foreign_ops
             [
               `Rename
                 Journal.
                   {
                     src = "w";
                     dst = "y";
                     size = None;
                     is_dir = true;
                     id = Some third;
                   };
             ])
     in
     let* dirs = local_dirs () in
     step "local: %s" (String.concat ", " dirs);
     let* after = show_markers "root after" Stored_key.root_id in
     check "it applied" ok;
     check "the earlier copy is left where it was"
       (List.assoc_opt "y (conflicted copy from test)" after = Some ours);
     check "and the folder it displaced takes a name of its own"
       (List.assoc_opt "y (conflicted copy 2 from test)" after = Some peers);

     case "a peer's rename onto the same folder retires the stale source";
     let* () = F.mkdir (Lk.dir "s") in
     let* () = settle () in
     let* id =
       Folder_ids_lwt.lookup_id ~cache_root:root ~domain_name:C.domain_name
         (Lk.dir "s")
     in
     let id = Option.get id in
     (* The mirror as droppy's was: the folder already at the rename's
        destination, and its source back beside it under the same id. *)
     let* () = Ck.create_dir (Lk.dir "t") in
     let* () =
       Io_lwt.Fs.atomic_write (marker_path "t")
         (Folder.marker_to_string { Folder.name = "t"; id })
     in
     let* ok =
       attempt "apply the peer's rename s -> t" (fun () ->
           F.apply_foreign_ops
             [
               `Rename
                 Journal.
                   {
                     src = "s";
                     dst = "t";
                     size = None;
                     is_dir = true;
                     id = Some id;
                   };
             ])
     in
     let* dirs = local_dirs () in
     step "local: %s" (String.concat ", " dirs);
     let lookup rel =
       Folder_ids_lwt.lookup_id ~cache_root:root ~domain_name:C.domain_name
         (Lk.dir rel)
     in
     let* at_t = lookup "t" in
     let* at_copy = lookup "s (conflicted copy from test)" in
     check "it applied" ok;
     check "the folder keeps its id at the destination" (at_t = Some id);
     check "the stale source kept its content under a name holding no id"
       (List.mem "s (conflicted copy from test)" dirs && at_copy = None);
     let* named =
       Folder_ids_lwt.key_of_id ~cache_root:root ~domain_name:C.domain_name
         ~root:Lk.root id
     in
     let* removal =
       Folder_ids_lwt.lookup_id_removed ~cache_root:root
         ~domain_name:C.domain_name
         (Lk.dir "s (conflicted copy from test)")
     in
     check "the id names the destination" (named = Some (Lk.dir "t"));
     check "and names nothing under the copy's path, even for a removal"
       (removal = None);
     let* () = settle () in
     let* after = show_markers "root after" Stored_key.root_id in
     check "the store is not told"
       (not (List.mem_assoc "s (conflicted copy from test)" after));

     case "a marker a same-parent rename left behind lends no id";
     (* The anchor agrees on the parent and not on the name, which is what a
        rename within one folder whose old marker's delete was lost leaves. *)
     let* anchor = show_anchor id in
     check "the folder is anchored under the root"
       (Option.map (fun a -> a.Folder.parent) anchor = Some Stored_key.root_id);
     let* () =
       Store.put
         ~key:
           (Stored_key.child_key ~prefix:C.domain_prefix
              ~folder_id:Stored_key.root_id "stale")
         ~data:
           (Bigstring.of_string
              (Folder.marker_to_string { Folder.name = "stale"; id }))
         ()
     in
     let* ok =
       attempt "apply a peer's mkdir stale, carrying no id" (fun () ->
           F.apply_foreign_ops [`Mkdir ("stale", None)])
     in
     let* at_stale = lookup "stale" in
     step "id at stale: %s"
       (match at_stale with Some i -> alias i | None -> "none");
     check "it applied" ok;
     check "the folder takes no id from the stale marker" (at_stale = None);

     case "a marker a move left behind holds its name against nobody";
     let* () =
       Store.put
         ~key:
           (Stored_key.child_key ~prefix:C.domain_prefix
              ~folder_id:Stored_key.root_id "vacant")
         ~data:
           (Bigstring.of_string
              (Folder.marker_to_string { Folder.name = "vacant"; id }))
         ()
     in
     let* () = F.mkdir (Lk.dir "vacant") in
     let* () = settle () in
     let* made = lookup "vacant" in
     let* after = show_markers "root after" Stored_key.root_id in
     check "a folder made under it keeps the name and its own id"
       (made <> None && made <> Some id && List.assoc_opt "vacant" after = made);

     case "a peer's folder op leaves alone a folder holding another id";
     let* () = F.mkdir (Lk.dir "m") in
     let* () = settle () in
     let* m_id = lookup "m" in
     let m_id = Option.get m_id in
     let dir_op id = Some ("peer-" ^ id) in
     let* ok =
       attempt "apply a peer's rename m -> m2 and rmdir m, of another folder"
         (fun () ->
           F.apply_foreign_ops
             [
               `Rename
                 Journal.
                   {
                     src = "m";
                     dst = "m2";
                     size = None;
                     is_dir = true;
                     id = dir_op "other";
                   };
               `Rmdir ("m", dir_op "other");
             ])
     in
     let* dirs = local_dirs () in
     let* at_m = lookup "m" in
     check "it applied" ok;
     check "ours is where it was, with its id"
       (List.mem "m" dirs && (not (List.mem "m2" dirs)) && at_m = Some m_id);

     case "a peer's mkdir onto a folder of ours moves ours aside";
     let* ok =
       attempt "apply a peer's mkdir m" (fun () ->
           F.apply_foreign_ops [`Mkdir ("m", dir_op "mkdir")])
     in
     let* dirs = local_dirs () in
     let* at_m = lookup "m" in
     let* at_copy = lookup "m (conflicted copy from test)" in
     step "local m: %s, copy: %s"
       (Option.fold ~none:"none" ~some:alias at_m)
       (Option.fold ~none:"none" ~some:alias at_copy);
     let* after = show_markers "root after" Stored_key.root_id in
     check "it applied" ok;
     check "the peer's folder has the name and its id"
       (List.mem "m" dirs && at_m = dir_op "mkdir");
     check "ours keeps its id under a name of its own" (at_copy = Some m_id);
     check "and the store is told ours moved"
       (List.assoc_opt "m (conflicted copy from test)" after = Some m_id
       && not (List.mem_assoc "m" after));

     case "a peer's mkdir of a folder that lives here under another name";
     let* ok =
       attempt "apply a peer's mkdir gone, naming ours" (fun () ->
           F.apply_foreign_ops [`Mkdir ("gone", Some m_id)])
     in
     let* dirs = local_dirs () in
     let* named =
       Folder_ids_lwt.key_of_id ~cache_root:root ~domain_name:C.domain_name
         ~root:Lk.root m_id
     in
     check "it applied" ok;
     check "nothing is created, and the id still names ours"
       ((not (List.mem "gone" dirs))
       && named = Some (Lk.dir "m (conflicted copy from test)"));

     (* The store files a peer's folder under the name this client's own folder
        left, and this client could not adopt it: the peer's put must not be
        answered from the namespace of the folder this client remembers there. *)
     case "a peer's put under a name this client moved away from";
     let* () = F.mkdir (Lk.dir "moved-from") in
     let* () = settle () in
     let* from_id = lookup "moved-from" in
     let from_id = Option.get from_id in
     let* () =
       Store.put
         ~key:
           (Stored_key.child_key ~prefix:C.domain_prefix ~folder_id:from_id
              "x.txt")
         ~data:
           (Bigstring.of_string
              (Tsync_manifest.Manifest.encode ~name:"x.txt" ~size:0L
                 ~chunk_size:4 ~mtime:0. ~h1:(String.make 16 'a')
                 ~h2:(String.make 16 'b') ~symlink:None ~keys:[]))
         ()
     in
     Mq.set_paused true;
     let* () = F.rename ~src:(Lk.dir "moved-from") ~dst:(Lk.dir "moved-to") in
     let from_marker =
       Stored_key.child_key ~prefix:C.domain_prefix
         ~folder_id:Stored_key.root_id "moved-from"
     in
     let* () =
       Store.put ~key:from_marker
         ~data:
           (Bigstring.of_string
              (Folder.marker_to_string
                 { Folder.name = "moved-from"; id = "peer-folder" }))
         ()
     in
     let* ok =
       attempt ~settled:false "apply a peer's put moved-from/x.txt" (fun () ->
           F.apply_foreign_ops [`Put ("moved-from/x.txt", 0L)])
     in
     Mq.set_paused false;
     let* () = settle () in
     let* dirs = local_dirs () in
     let written =
       Sys.file_exists
         (Cache_layout.manifest_path ~cache_root:root ~domain_name:C.domain_name
            (Lk.file "moved-from/x.txt"))
     in
     step "local: %s" (String.concat ", " dirs);
     check "it applied" ok;
     check "this client's own file is not taken for the peer's under the name"
       (not written);

     report ~expected:40 ();
     Lwt.return_unit);
  Scratch.cleanup root
