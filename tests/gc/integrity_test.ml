(* Integrity (spec 05 §4.10): a tree projected from its log is healthy; one of
   each finding planted on it is reported; a tree behind its log makes no
   finding; corrupt chunks are repaired, as a dry run first. *)

open Tsync_core
open Tsync_store
open Tsync_remote
open Tsync_gc

let p fmt = Printf.printf fmt
let d = Domain_name.v "d"

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-integrity-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  let main = Local.create ~name:"main" (Filename.concat root "store")
  and replica = Local.create ~name:"replica" (Filename.concat root "replica") in
  let ids =
    [
      ("live", "0000000000a1-1");
      ("other", "0000000000a2-1");
      ("moved", "0000000000a4-1");
      ("stray", "0000000000a5-1");
      ("unanchored", "0000000000a6-1");
    ]
  in
  let id n = Folder_id.v (List.assoc n ids) in
  let alias s =
    List.fold_left
      (fun s (n, i) -> Text.replace_all ~sub:i ~by:("<" ^ n ^ ">") s)
      s ids
    |> Text.replace_all ~sub:"tsync/d/" ~by:""
  in
  let knowledge =
    { Composite.is_index = (fun _ -> false); is_log = (fun _ -> false) }
  in
  let context name (main : Store.t) members =
    let composite =
      Composite.create ~domain:d
        ~data_dir:(Filename.concat root name)
        ~owner:true ~poke:ignore ~knowledge
        ({ Composite.name = "main"; role = Main; store = main } :: members)
    in
    (module struct
      let domain = d
      let store = Composite.store composite
      let composite = composite
      let versioning = false
      let chunk_size_config = Some 8
      let max_downloads = 4
      let max_chunk_buffers = 4
    end : Context.S)
  in
  Rt.run_sync (fun () ->
      let module C =
        (val context "data" main
               [{ name = "replica"; role = Replica; store = replica }])
      in
      let module R = Remote.Make (C) in
      let module P = Projection.Make (C) in
      let module I = Integrity.Make (C) in
      let log = Log_store.create d C.store in
      let at parent name = { Algebra.parent; name } in
      let content name body =
        Log_entry.Known
          (R.upload_chunks ~name ~size:(String.length body) ~chunk_size:8
             ~mtime:1. (fun _ -> Bytes (Bigstring.of_string body)))
      in
      let commit ?(project = true) n commands =
        ignore
          (Log_store.create_entry log n
             (Log_entry.encode { author = "a"; commands }));
        if project then (
          P.apply ~before_write:ignore commands;
          Log_store.raise_tree_head log n)
      in
      let keep = content "keep.txt" "kept" in
      commit 1
        [
          `Folder (id "live", None, Some (at Folder_id.root "live"));
          `Folder (id "other", None, Some (at Folder_id.root "other"));
          `Folder (id "moved", None, Some (at (id "other") "before"));
          `File (at (id "live") "keep.txt", None, Some keep);
          `File (at (id "live") "gone.txt", None, Some keep);
        ];
      commit 2
        [
          `Folder
            ( id "moved",
              Some (at (id "other") "before"),
              Some (at Folder_id.root "moved") );
        ];
      let sound n = Chunk_key.of_body n in
      let chunk_name c =
        List.fold_left
          (fun s n ->
            if Chunk_key.equal c (sound n) then Printf.sprintf "<%s>" n else s)
          (Chunk_key.to_string c)
          ["on main"; "own copy"; "nowhere"]
      in
      let show (r : Integrity.report) =
        p "healthy %b\n" (Integrity.healthy r);
        (match r.tree with
          | Behind { tree_head; head } ->
              p "  behind: tree head %d, head %d; no finding made\n" tree_head
                head
          | Findings findings ->
              List.iter
                (fun f -> p "  %s\n" (alias (Integrity.describe f)))
                findings);
        List.iter
          (fun (c : Integrity.corrupt) ->
            p "  corrupt on %s: %s\n" c.member (chunk_name c.chunk))
          r.corrupt
      in
      p "== a tree projected from its log\n";
      show (I.report ());
      p "\n== one of each finding\n";
      let put key body = main.put key (Bigstring.of_string body) in
      put
        (Key.child d (id "other") "before")
        (Folder.marker_body { name = "before"; id = id "moved" });
      put
        (Key.child d Folder_id.root "unanchored")
        (Folder.marker_body { name = "unanchored"; id = id "unanchored" });
      ignore (main.delete (Key.child d Folder_id.root "other"));
      (match content "keep.txt" "changed" with
        | Known m -> put (Key.child d (id "live") "keep.txt") m.body
        | _ -> ());
      ignore (main.delete (Key.child d (id "live") "gone.txt"));
      (match content "lost.txt" "lost" with
        | Known m -> put (Key.child d (id "stray") "lost.txt") m.body
        | _ -> ());
      let planted = I.report () in
      show planted;
      p "a cancelled report: %s\n"
        (match I.report ~cancelled:(Fun.const true) () with
          | _ -> "finished"
          | exception Fail.E f -> f.reason);
      p "\n== an entry above the tree head\n";
      commit ~project:false 3
        [`Folder (id "stray", None, Some (at Folder_id.root "stray"))];
      show (I.report ());
      p "\n== corrupt chunks\n";
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
      let chunk_outcome = function
        | Integrity.Cleared -> "cleared"
        | Repaired from -> "repaired from " ^ from
        | Unrepairable -> "unrepairable"
      in
      let repair ~apply =
        List.iter
          (fun ((c : Integrity.corrupt), o) ->
            p "  %s on %s -> %s\n" (chunk_name c.chunk) c.member
              (chunk_outcome o))
          (I.repair_chunks ~apply (I.report ()))
      in
      let listing () =
        List.map
          (fun (s : Store.t) ->
            List.map
              (fun (e : Store.entry) -> (Key.to_string e.key, e.etag))
              (s.list_prefix Key.root))
          [main; replica]
      in
      let before = listing () in
      repair ~apply:false;
      p "dry run changed nothing: %b\n" (listing () = before);
      repair ~apply:true;
      p "replica's copy of <on main> sound: %b\n"
        (replica.get_opt (Key.chunk d (sound "on main"))
        = Some (Bigstring.of_string "on main"));
      p "the tree findings are still there, untouched: %b\n"
        (Log_store.raise_tree_head log 3;
         match ((I.report ()).tree, planted.tree) with
           | Findings now, Findings then_ ->
               List.for_all (fun f -> List.mem f now) then_
           | _ -> false);
      p "\n== a namespace that cannot be listed fails the report\n";
      let unlistable = Key.namespace d (id "live") in
      let flaky =
        {
          main with
          list_prefix =
            (fun ?max_keys prefix ->
              if Key.prefix_to_string prefix = Key.prefix_to_string unlistable
              then Fail.raise_ Link "listing failed"
              else main.list_prefix ?max_keys prefix);
          list_many = None;
        }
      in
      let module F = (val context "data-flaky" flaky []) in
      let module I = Integrity.Make (F) in
      p "%s\n"
        (match I.report () with
          | r -> Printf.sprintf "a report, healthy %b" (Integrity.healthy r)
          | exception Fail.E f -> "no report: " ^ f.reason));
  Test_support.finish root
