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
        { Composite.is_index = (fun _ -> false); is_log = (fun _ -> false) }
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
      let module P = Projection.Make (C) in
      let apply commands = P.apply ~before_write:ignore commands in
      let at parent name = { Algebra.parent; name } in
      let w = Folder_id.mint ~uuid:"aaaaaaaaaaaa" ~counter:1 in
      winner := Folder_id.to_string w;
      apply [`Folder (w, None, Some (at Folder_id.root "Photos"))];
      p "== files and deduplication\n";
      let build name content =
        R.upload_chunks ~name ~size:(String.length content) ~chunk_size:8
          ~mtime:1. (fun i ->
            Bytes
              (Bigstring.of_string
                 (String.sub content (i * 8)
                    (min 8 (String.length content - (i * 8))))))
      in
      let upload ?before name content =
        let m = build name content in
        apply
          [
            `File
              ( at w name,
                Option.map (fun b -> Log_entry.Known b) before,
                Some (Known m) );
          ];
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
      ignore (upload ~before:a "a.txt" "changed");
      p "versions of a.txt: %d\n" (List.length (R.list_versions w "a.txt"));
      apply [`File (at w "c.txt", None, Some (Known b))];
      p "a manifest is recorded under its key's leaf: %s\n"
        (match R.get_slot w "c.txt" with
          | Some b -> (Option.get (Manifest.decode b)).name
          | None -> "missing");
      p "\n== the tree\n";
      let sub = Folder_id.mint ~uuid:"aaaaaaaaaaaa" ~counter:7 in
      apply [`Folder (sub, None, Some (at w "Trip"))];
      let names =
        T.fold_tree Folder_id.root ~root_path:""
          (fun acc path (e : Tree.entry) ->
            (match e.body with
              | Dir m -> Names.join path (m.name ^ "/")
              | File m -> Names.join path m.name)
            :: acc)
          []
      in
      p "%s\n" (String.concat " " (List.sort compare names));
      p "find Photos/Trip: %s\n"
        (match T.find Folder_id.root ["Photos"; "Trip"] with
          | `Folder id ->
              if Folder_id.equal id sub then "the folder" else "another"
          | _ -> "missing");
      p "\n== a listing that fails once is walked again with its subtree\n";
      apply
        [
          `Folder
            ( Folder_id.mint ~uuid:"aaaaaaaaaaaa" ~counter:8,
              None,
              Some (at sub "Day1") );
        ];
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
      let old_marker = Option.get (main.get_opt (Key.child d w "Trip")) in
      apply
        [`Folder (sub, Some (at w "Trip"), Some (at Folder_id.root "Moved"))];
      main.put (Key.child d w "Trip") old_marker;
      let folders () =
        String.concat " "
          (List.rev
             (T.fold_tree
                ~on_unusable:(Skip (fun _ -> ()))
                Folder_id.root ~root_path:""
                (fun acc path (e : Tree.entry) ->
                  match e.body with
                    | Dir m -> Names.join path m.name :: acc
                    | File _ -> acc)
                []))
      in
      p "listed at: %s\n" (folders ());
      p "old path: %s\n"
        (match T.find Folder_id.root ["Photos"; "Trip"] with
          | `Missing -> "missing"
          | _ -> "found");
      ignore (main.delete (Key.child d w "Trip"));
      p "\n== a marker whose folder has no anchor is disowned\n";
      let stray = Folder_id.mint ~uuid:"bbbbbbbbbbbb" ~counter:1 in
      main.put
        (Key.child d Folder_id.root "Stray")
        (Bigstring.of_string
           (Folder.marker_body { name = "Stray"; id = stray }));
      p "listed at: %s\n" (folders ());
      ignore (main.delete (Key.child d Folder_id.root "Stray"));
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
      p "\n== the main's chunk size is binding\n";
      let stating =
        {
          C.store with
          capabilities =
            (fun _ ->
              { Store.no_caps with chunk_size = Some Chunking.chunk_size_min });
        }
      in
      let module Disagreeing = Remote.Make (struct
        include C

        let store = stating
      end) in
      let module Following = Remote.Make (struct
        include C

        let store = stating
        let chunk_size_config = None
      end) in
      p "before the main answered: %d and %d\n"
        (Disagreeing.chunk_size ())
        (Following.chunk_size () / Chunking.default_chunk_size);
      Rt.sleep 0.2;
      p "configured with another size: %s\n"
        (match Disagreeing.chunk_size () with
          | cs -> string_of_int cs
          | exception Fail.E f ->
              Text.replace_all
                ~sub:(string_of_int Chunking.chunk_size_min)
                ~by:"<the main's>" f.reason);
      p "not configured: the main's is used: %b\n"
        (Following.chunk_size () = Chunking.chunk_size_min);
      p "\n== store\n";
      dump ());
  Test_support.finish root
