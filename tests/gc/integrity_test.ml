(* Integrity (spec 05 §4.10, gc.md §4.6): one of each finding planted on a
   local main, reported, repaired as a dry run, repaired, reported again. *)

open Tsync_core
open Tsync_store
open Tsync_gc

let p fmt = Printf.printf fmt
let d = Domain_name.v "d"
let day = 86400.

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-integrity-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  let store_root = Filename.concat root "store" in
  let main = Local.create ~name:"main" store_root
  and replica = Local.create ~name:"replica" (Filename.concat root "replica") in
  let now = Unix.gettimeofday () in
  let ids =
    [
      ("live", "0000000000a1-1");
      ("other", "0000000000a2-1");
      ("twice", "0000000000a3-1");
      ("moved", "0000000000a4-1");
      ("lost", "0000000000a5-1");
      ("nested", "0000000000a6-1");
      ("young", "0000000000a7-1");
      ("tomb", "0000000000a8-1");
      ("gone", "0000000000a9-1");
      ("binned", "0000000000b1-1");
      ("unbinned", "0000000000b2-1");
    ]
  in
  let id n = Folder_id.v (List.assoc n ids) in
  let alias s =
    List.fold_left
      (fun s (n, i) -> Text.replace_all ~sub:i ~by:("<" ^ n ^ ">") s)
      s ids
    |> Text.replace_all ~sub:"tsync/d/" ~by:""
  in
  let put ?(age = 0.) key body =
    main.put key (Bigstring.of_string body);
    let t = now -. (age *. day) in
    Unix.utimes (Filename.concat store_root (Key.to_string key)) t t
  in
  let marker ?age parent name child =
    put ?age (Key.child d parent name)
      (Folder.marker_body { name; id = id child })
  and anchor ?age child parent name =
    put ?age
      (Key.anchor d (id child))
      (Folder.anchor_body { parent; aname = name })
  in
  let chunk = Chunk_key.of_body "" in
  let file ?age parent name =
    put ?age (Key.child d parent name)
      (Manifest.make ~name ~size:0 ~mtime:0. ~chunk_size:Chunking.chunk_size_min
         [chunk])
        .body
  in
  Rt.run_sync (fun () ->
      put (Key.chunk d chunk) "";
      marker Folder_id.root "live" "live";
      anchor "live" Folder_id.root "live";
      file (id "live") "keep.txt";
      marker Folder_id.root "other" "other";
      anchor "other" Folder_id.root "other";
      marker Folder_id.root "twice" "twice";
      marker (id "live") "twice-again" "twice";
      marker Folder_id.root "moved" "moved";
      anchor "moved" Folder_id.root "moved";
      marker (id "other") "moved-before" "moved";
      put (Key.trash_entry d "e1")
        (Folder.trash_body { name = "live"; id = id "live" } ~path:"live");
      anchor ~age:60. "lost" (id "gone") "lost";
      file ~age:60. (id "lost") "a.txt";
      anchor ~age:60. "nested" (id "lost") "nested";
      file ~age:60. (id "nested") "b.txt";
      file (id "young") "c.txt";
      anchor ~age:60. "tomb" Folder_id.root "tomb";
      anchor "binned" Folder_id.trash "binned";
      file (id "binned") "d.txt";
      put (Key.trash_entry d "e2")
        (Folder.trash_body { name = "binned"; id = id "binned" } ~path:"binned");
      file (id "unbinned") "e.txt";
      put (Key.trash_entry d "e3")
        (Folder.trash_body
           { name = "unbinned"; id = id "unbinned" }
           ~path:"old/unbinned");
      let sound n = Chunk_key.of_body n in
      List.iter
        (fun n ->
          main.put (Key.chunk d (sound n)) (Bigstring.of_string n);
          replica.put (Key.chunk d (sound n)) (Bigstring.of_string n))
        ["on main"; "own copy"];
      replica.put (Key.chunk d (sound "on main")) (Bigstring.of_string "rot");
      List.iter
        (fun ((s : Store.t), n) ->
          s.put (Key.marker d (sound n)) (Bigstring.of_string "{}"))
        [(replica, "on main"); (main, "own copy"); (main, "nowhere")];
      let composite =
        Composite.create ~domain:d
          ~data_dir:(Filename.concat root "data")
          ~owner:true ~poke:ignore
          ~knowledge:
            {
              Composite.is_index = (fun _ -> false);
              is_journal = (fun _ -> false);
            }
          [
            { name = "main"; role = Main; store = main };
            { name = "replica"; role = Replica; store = replica };
          ]
      in
      let module C = struct
        let domain = d
        let store = Composite.store composite
        let composite = composite
        let versioning = true
        let chunk_size_config = None
        let max_downloads = 4
        let max_chunk_buffers = 4
      end in
      let module I = Integrity.Make (C) in
      let chunk_name c =
        List.fold_left
          (fun s n ->
            if Chunk_key.equal c (sound n) then Printf.sprintf "<%s>" n else s)
          (Chunk_key.to_string c)
          ["on main"; "own copy"; "nowhere"]
      in
      let show (r : Integrity.report) =
        p "healthy %b, %d tombstones\n" (Integrity.healthy r) r.tombstones;
        List.iter
          (fun f -> p "  %s\n" (alias (Integrity.describe f)))
          r.findings;
        List.iter
          (fun (c : Integrity.corrupt) ->
            p "  corrupt on %s: %s\n" c.member (chunk_name c.chunk))
          r.corrupt
      in
      let tree_outcome = function
        | Integrity.Deleted -> "deleted"
        | Anchored -> "anchored"
        | Adopted -> "adopted"
        | Young -> "young"
        | Nested -> "nested"
        | Left -> "left"
        | Failed r -> "failed: " ^ r
      and chunk_outcome = function
        | Integrity.Cleared -> "cleared"
        | Repaired from -> "repaired from " ^ from
        | Unrepairable -> "unrepairable"
      in
      let repair ~apply =
        let r = I.report () in
        List.iter
          (fun (f, o) ->
            p "  %s -> %s\n" (alias (Integrity.describe f)) (tree_outcome o))
          (I.repair_tree ~apply r);
        List.iter
          (fun ((c : Integrity.corrupt), o) ->
            p "  %s on %s -> %s\n" (chunk_name c.chunk) c.member
              (chunk_outcome o))
          (I.repair_chunks ~apply r)
      in
      let listing () =
        List.map
          (fun (s : Store.t) ->
            List.map
              (fun (e : Store.entry) -> (Key.to_string e.key, e.etag))
              (s.list_prefix Key.root))
          [main; replica]
      in
      p "== report\n";
      show (I.report ());
      p "\n== repair, dry run\n";
      let before = listing () in
      repair ~apply:false;
      p "dry run changed nothing: %b\n" (listing () = before);
      p "\n== repair\n";
      repair ~apply:true;
      p "\n== report after the repair\n";
      show (I.report ());
      let trash =
        List.map
          (fun (f : Tsync_remote.Tree.Make(C).trashed) ->
            Printf.sprintf "%s at %s"
              (alias (Folder_id.to_string f.id))
              (Option.value ~default:"?" f.path))
          (let module T = Tsync_remote.Tree.Make (C) in
          T.trashed ())
      in
      p "trash: %s\n" (String.concat ", " (List.sort compare trash));
      p "replica's copy of <on main> sound: %b\n"
        (replica.get_opt (Key.chunk d (sound "on main"))
        = Some (Bigstring.of_string "on main")));
  Fs.rm_rf root
