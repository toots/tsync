open Tsync_core
open Tsync_store
open Tsync_remote

module Str_replace = struct
  let all ~sub ~by s =
    let b = Buffer.create (String.length s) and n = String.length sub in
    let rec go i =
      if i > String.length s - n then Buffer.add_string b (String.sub s i (String.length s - i))
      else if String.sub s i n = sub then (Buffer.add_string b by; go (i + n))
      else (Buffer.add_char b s.[i]; go (i + 1))
    in
    go 0;
    Buffer.contents b
end

let p fmt = Printf.printf fmt
let root = Filename.concat (Filename.get_temp_dir_name ()) (Printf.sprintf "tsync-remote-%d" (Unix.getpid ()))

let () =
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let d = Domain_name.v "photos" in
      let main = Local.create ~name:"main" (Filename.concat root "store") in
      let knowledge = { Composite.chunk_names = Manifest.chunk_names; generation = (fun () -> Some 0); is_index = (fun _ -> false); is_journal = (fun _ -> false) } in
      let composite = Composite.create ~domain:d ~data_dir:(Filename.concat root "data") ~owner:true ~poke:ignore ~knowledge [{ name = "main"; role = Main; store = main }] in
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
        let s = if !winner = "" then s else Str_replace.all ~sub:!winner ~by:"<photos-id>" s in
        match String.rindex_opt s '/' with
          | Some i when String.length s - i > 15 && String.for_all (fun c -> c >= '0' && c <= '9') (String.sub s (i + 1) (String.length s - i - 1)) ->
              String.sub s 0 (i + 1) ^ "<ns>"
          | _ -> s
      in
      let dump () =
        List.iter
          (fun (e : Store.entry) -> p "  %s (%d)\n" (alias (Key.to_string e.key)) e.size)
          (main.list_prefix (Key.domain_prefix d))
      in
      p "== five clients claim one name\n";
      let ids = List.map (fun i -> Folder_id.mint ~uuid:(Printf.sprintf "%012x" i) ~counter:1) [1; 2; 3; 4; 5] in
      let answers = Rt.map_concurrently (fun id -> (id, T.claim ~parent:Folder_id.root ~name:"Photos" id)) ids in
      let winners = List.filter (fun (_, a) -> a = `Won) answers in
      let adopted = List.filter_map (fun (_, a) -> match a with `Taken j -> Some j | _ -> None) answers in
      let w = fst (List.hd winners) in
      winner := Folder_id.to_string w;
      p "won: %d; every loser adopts the winner: %b\n" (List.length winners) (List.for_all (Folder_id.equal w) adopted);
      p "confirm: %s\n" (match T.confirm ~parent:Folder_id.root ~name:"Photos" w with `Final -> "final" | `Reclaimed -> "reclaimed" | `Lost _ -> "lost");
      p "\n== files and deduplication\n";
      let upload name content =
        let m =
          R.upload_chunks ~name ~size:(String.length content) ~chunk_size:8 ~mtime:1.
            (fun i -> Bytes (String.sub content (i * 8) (min 8 (String.length content - (i * 8)))))
        in
        R.publish ~parent:w ~leaf:name m;
        m
      in
      let a = upload "a.txt" "0123456789abcdefXYZ" in
      let b = upload "b.txt" "0123456789abcdef" in
      p "a: %d chunks, b: %d chunks, chunk objects: %d\n" a.count b.count
        (List.length (main.list_prefix (Key.chunks d)));
      let e = upload "empty" "" in
      p "empty file names the empty chunk once: %b\n" (e.count = 1 && Chunk_key.equal (Manifest.key e 0) Chunk_key.empty);
      ignore (upload "a.txt" "changed");
      p "versions of a.txt: %d\n" (List.length (R.list_versions w "a.txt"));
      R.rename_file ~src:(w, "b.txt") ~dst:(w, "c.txt");
      p "renamed manifest records its new leaf: %s\n"
        (match R.get_slot w "c.txt" with Some b -> (Option.get (Manifest.decode b)).name | None -> "missing");
      p "\n== the tree\n";
      let sub = Folder_id.mint ~uuid:"aaaaaaaaaaaa" ~counter:7 in
      ignore (T.claim ~parent:w ~name:"Trip" sub);
      let names =
        T.fold_tree Folder_id.root ~root_path:"" (fun acc path (e : Tree.entry) ->
            (match e.body with Dir m -> Names.join path (m.name ^ "/") | File m -> Names.join path m.name) :: acc) []
      in
      p "%s\n" (String.concat " " (List.rev names));
      p "find Photos/Trip: %s\n" (match T.find Folder_id.root ["Photos"; "Trip"] with `Folder id -> if Folder_id.equal id sub then "the folder" else "another" | _ -> "missing");
      p "\n== a move whose old-marker delete was lost\n";
      ignore (T.place sub ~parent:Folder_id.root ~name:"Moved");
      p "listed at: %s\n" (String.concat " " (List.rev (T.fold_tree Folder_id.root ~root_path:"" (fun acc path (e : Tree.entry) -> match e.body with Dir m -> Names.join path m.name :: acc | File _ -> acc) [])));
      p "old path: %s\n" (match T.find Folder_id.root ["Photos"; "Trip"] with `Missing -> "missing" | _ -> "found");
      p "\n== trash and restore\n";
      T.trash sub ~old:(Folder_id.root, "Moved") ~path:"Moved";
      p "trash entries: %d; anchor in trash: %b; live: %s\n" (List.length (T.trash_entries ()))
        (match T.anchor sub with Some a -> Folder.in_trash a | None -> false)
        (match T.find Folder_id.root ["Moved"] with `Missing -> "gone" | _ -> "still there");
      ignore (T.restore sub ~parent:Folder_id.root ~name:"Restored");
      p "after restore: entries %d, found %b\n" (List.length (T.trash_entries ())) (T.find Folder_id.root ["Restored"] = `Folder sub);
      p "\n== a placement onto a taken name\n";
      let other = Folder_id.mint ~uuid:"bbbbbbbbbbbb" ~counter:1 in
      p "%s\n" (match T.place other ~parent:Folder_id.root ~name:"Photos" with `Taken j -> if Folder_id.equal j w then "taken by Photos" else "taken" | `Placed -> "PLACED OVER" | `Taken_by_file -> "file");
      p "\n== store\n";
      dump ());
  Fs.rm_rf root
