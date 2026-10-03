open Tsync_core
open Tsync_store
open Tsync_remote

module Str_replace = struct
  let all ~sub ~by s =
    let b = Buffer.create (String.length s) and n = String.length sub in
    let rec go i =
      if i > String.length s - n then
        Buffer.add_string b (String.sub s i (String.length s - i))
      else if String.sub s i n = sub then (
        Buffer.add_string b by;
        go (i + n))
      else (
        Buffer.add_char b s.[i];
        go (i + 1))
    in
    go 0;
    Buffer.contents b
end

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-remote-%d" (Unix.getpid ()))

let () =
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let d = Domain_name.v "photos" in
      let main = Local.create ~name:"main" (Filename.concat root "store") in
      let knowledge =
        { Composite.is_index = (fun _ -> false); is_journal = (fun _ -> false) }
      in
      let composite =
        Composite.create ~domain:d
          ~data_dir:(Filename.concat root "data")
          ~owner:true ~poke:ignore ~knowledge
          [{ name = "main"; role = Main; store = main }]
      in
      let module C = struct
        let domain = d
        let store = Composite.store composite
        let composite = composite
        let versioning = true
        let chunk_size_config = Some 8
        let max_downloads = 8
        let max_chunk_buffers = 4
      end in
      let module R = Remote.Make (C) in
      let module T = Tree.Make (C) in
      let winner = ref "" in
      let alias s =
        let s =
          if !winner = "" then s
          else Str_replace.all ~sub:!winner ~by:"<photos-id>" s
        in
        match String.rindex_opt s '/' with
          | Some i
            when String.length s - i > 15
                 && String.for_all
                      (fun c -> c >= '0' && c <= '9')
                      (String.sub s (i + 1) (String.length s - i - 1)) ->
              String.sub s 0 (i + 1) ^ "<ns>"
          | _ -> s
      in
      let dump () =
        List.iter
          (fun (e : Store.entry) ->
            p "  %s (%d)\n" (alias (Key.to_string e.key)) e.size)
          (main.list_prefix (Key.domain_prefix d))
      in
      p "== five clients claim one name\n";
      let ids =
        List.map
          (fun i -> Folder_id.mint ~uuid:(Printf.sprintf "%012x" i) ~counter:1)
          [1; 2; 3; 4; 5]
      in
      let answers =
        Rt.map_concurrently
          (fun id -> (id, T.claim ~parent:Folder_id.root ~name:"Photos" id))
          ids
      in
      let winners = List.filter (fun (_, a) -> a = `Won) answers in
      let adopted =
        List.filter_map
          (fun (_, a) -> match a with `Taken j -> Some j | _ -> None)
          answers
      in
      let w = fst (List.hd winners) in
      winner := Folder_id.to_string w;
      p "won: %d; every loser adopts the winner: %b\n" (List.length winners)
        (List.for_all (Folder_id.equal w) adopted);
      p "confirm: %s\n"
        (match T.confirm ~parent:Folder_id.root ~name:"Photos" w with
          | `Final -> "final"
          | `Reclaimed -> "reclaimed"
          | `Lost _ -> "lost");
      p "\n== files and deduplication\n";
      let upload name content =
        let m =
          R.upload_chunks ~name ~size:(String.length content) ~chunk_size:8
            ~mtime:1. (fun i ->
              Bytes
                (Bigstring.of_string
                   (String.sub content (i * 8)
                      (min 8 (String.length content - (i * 8))))))
        in
        R.publish ~parent:w ~leaf:name m;
        m
      in
      let a = upload "a.txt" "0123456789abcdefXYZ" in
      let b = upload "b.txt" "0123456789abcdef" in
      p "a: %d chunks, b: %d chunks, chunk objects: %d\n" a.count b.count
        (List.length (main.list_prefix (Key.chunks d)));
      (let n = 400 in
       let total = ref 0 and calls = Atomic.make 0 in
       let content = String.init (n * 8) (fun i -> Char.chr (i mod 251)) in
       ignore
         (R.upload_chunks ~name:"counted" ~size:(n * 8) ~chunk_size:8 ~mtime:1.
            ~sent:(fun k ->
              let seen = !total in
              Atomic.incr calls;
              Thread.yield ();
              total := seen + k)
            (fun i ->
              Bytes (Bigstring.of_string (String.sub content (i * 8) 8))));
       p "parallel chunk uploads count every byte sent: %b\n"
         (!total = 8 * Atomic.get calls));
      let e = upload "empty" "" in
      p "empty file names the empty chunk once: %b\n"
        (e.count = 1 && Chunk_key.equal (Manifest.key e 0) Chunk_key.empty);
      ignore (upload "a.txt" "changed");
      p "versions of a.txt: %d\n" (List.length (R.list_versions w "a.txt"));
      R.rename_file ~src:(w, "b.txt") ~dst:(w, "c.txt");
      p "renamed manifest records its new leaf: %s\n"
        (match R.get_slot w "c.txt" with
          | Some b -> (Option.get (Manifest.decode b)).name
          | None -> "missing");
      p "\n== the tree\n";
      let sub = Folder_id.mint ~uuid:"aaaaaaaaaaaa" ~counter:7 in
      ignore (T.claim ~parent:w ~name:"Trip" sub);
      let names =
        T.fold_tree Folder_id.root ~root_path:""
          (fun acc path (e : Tree.entry) ->
            (match e.body with
              | Dir m -> Names.join path (m.name ^ "/")
              | File m -> Names.join path m.name)
            :: acc)
          []
      in
      p "%s\n" (String.concat " " (List.rev names));
      p "find Photos/Trip: %s\n"
        (match T.find Folder_id.root ["Photos"; "Trip"] with
          | `Folder id ->
              if Folder_id.equal id sub then "the folder" else "another"
          | _ -> "missing");
      p "\n== a listing that fails once is walked again with its subtree\n";
      ignore
        (T.claim ~parent:sub ~name:"Day1"
           (Folder_id.mint ~uuid:"aaaaaaaaaaaa" ~counter:8));
      let fail_once = Atomic.make true in
      let photos = Key.prefix_to_string (Key.namespace d w) in
      let check prefix =
        if
          Key.prefix_to_string prefix = photos
          && Atomic.exchange fail_once false
        then Fail.raise_ Fail.Link "listing lost"
      in
      let module Flaky = Tree.Make (struct
        include C

        let store =
          {
            C.store with
            list_prefix =
              (fun ?max_keys prefix ->
                check prefix;
                C.store.list_prefix ?max_keys prefix);
            list_many =
              Option.map
                (fun f prefixes ->
                  List.iter check prefixes;
                  f prefixes)
                C.store.list_many;
          }
      end) in
      let unusable = ref 0 in
      let dirs =
        Flaky.fold_tree
          ~on_unusable:(Skip (fun _ -> incr unusable))
          Folder_id.root ~root_path:""
          (fun acc path (e : Tree.entry) ->
            match e.body with
              | Dir m -> Names.join path m.name :: acc
              | File _ -> acc)
          []
      in
      p "failed once: %b; unusable: %d; folders: %s\n"
        (not (Atomic.get fail_once))
        !unusable
        (String.concat " " (List.rev dirs));
      p "\n== a move whose old-marker delete was lost\n";
      ignore (T.place sub ~parent:Folder_id.root ~name:"Moved");
      p "listed at: %s\n"
        (String.concat " "
           (List.rev
              (T.fold_tree Folder_id.root ~root_path:""
                 (fun acc path (e : Tree.entry) ->
                   match e.body with
                     | Dir m -> Names.join path m.name :: acc
                     | File _ -> acc)
                 [])));
      p "old path: %s\n"
        (match T.find Folder_id.root ["Photos"; "Trip"] with
          | `Missing -> "missing"
          | _ -> "found");
      p "\n== trash and restore\n";
      T.trash sub ~old:(Folder_id.root, "Moved") ~path:"Moved";
      p "trash entries: %d; anchor in trash: %b; live: %s\n"
        (List.fold_left
           (fun n (f : T.trashed) -> n + List.length f.entries)
           0 (T.trashed ()))
        (match T.anchor sub with Some a -> Folder.in_trash a | None -> false)
        (match T.find Folder_id.root ["Moved"] with
          | `Missing -> "gone"
          | _ -> "still there");
      ignore (T.restore sub ~parent:Folder_id.root ~name:"Restored");
      p "after restore: entries %d, found %b\n"
        (List.fold_left
           (fun n (f : T.trashed) -> n + List.length f.entries)
           0 (T.trashed ()))
        (T.find Folder_id.root ["Restored"] = `Folder sub);
      p "\n== a folder trashed twice reports its newest path\n";
      let twice =
        List.init 5 (fun i ->
            Folder_id.mint ~uuid:"cccccccccccc" ~counter:(i + 1))
      in
      List.iter
        (fun id -> T.trash id ~old:(Folder_id.root, "One") ~path:"One")
        twice;
      Unix.sleepf 1.1;
      List.iter
        (fun id -> T.trash id ~old:(Folder_id.root, "Two") ~path:"Two")
        twice;
      let paths =
        List.filter_map
          (fun (f : T.trashed) ->
            if List.exists (Folder_id.equal f.id) twice then f.path else None)
          (T.trashed ())
      in
      p "paths: %s\n" (String.concat " " (List.sort compare paths));
      (* Their keys are random, and the store is listed below. *)
      List.iter
        (fun (f : T.trashed) ->
          if List.exists (Folder_id.equal f.id) twice then (
            List.iter
              (fun (e : Store.entry) -> ignore (main.delete e.key))
              f.entries;
            ignore (main.delete (Key.anchor d f.id))))
        (T.trashed ());
      p "\n== a placement onto a taken name\n";
      let other = Folder_id.mint ~uuid:"bbbbbbbbbbbb" ~counter:1 in
      p "%s\n"
        (match T.place other ~parent:Folder_id.root ~name:"Photos" with
          | `Taken j ->
              if Folder_id.equal j w then "taken by Photos" else "taken"
          | `Placed -> "PLACED OVER"
          | `Taken_by_file -> "file");
      p "\n== a range read is not queued behind whole-chunk reads\n";
      let module Slow = Remote.Make (struct
        include C

        let store =
          {
            C.store with
            get_opt =
              (fun k ->
                Rt.sleep 2.;
                C.store.get_opt k);
          }
      end) in
      let ck = Manifest.key a 0 in
      let busy =
        List.init 8 (fun _ -> Rt.async (fun () -> ignore (Slow.get_chunk ck)))
      in
      Rt.sleep 0.1;
      let t0 = Rt.now () in
      let range = Bigstring.to_string (Slow.get_chunk_range ck 2 3) in
      p "range %S within 0.5s: %b\n" range (Rt.now () -. t0 < 0.5);
      List.iter Rt.Promise.await busy;
      p "\n== store\n";
      dump ());
  Fs.rm_rf root
