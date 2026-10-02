open Tsync_core
open Tsync_store

let p = Contract.p

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-local-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let s = Local.create ~name:"local" root in
      Contract.run s;
      p "\n== local driver (backends/local §13)\n";
      let dir = Filename.concat root "tsync/d/l" in
      Fs.write_file_for_test (Filename.concat dir ".tsync-tmp-abc.tmp") "staged";
      Fs.write_file_for_test (Filename.concat dir ".syncthing.x.tmp") "user";
      Unix.mkdir (Filename.concat dir "sub") 0o755;
      Unix.symlink "/etc" (Filename.concat dir "link");
      p "listing: %s\n"
        (String.concat ","
           (List.map
              (fun (e : Store.entry) -> Key.rel (Key.prefix "tsync/d/l/") e.key)
              (s.list_prefix (Key.prefix "tsync/d/l/"))));
      Unix.symlink "/etc" (Filename.concat root "tsync/d/esc");
      p "read through a planted link: %s\n"
        (Contract.kind_of (fun () ->
             Contract.get s (Key.v "tsync/d/esc/passwd")));
      p "write through a planted link: %s\n"
        (Contract.kind_of (fun () -> Contract.put s (Key.v "tsync/d/esc/x") "x"));
      let chunk = "hello world" in
      let ck = Chunk_key.of_body chunk in
      let d = Domain_name.v "d" in
      Contract.put s (Key.chunk d ck) chunk;
      p "good chunk marker: %b\n" (Contract.get s (Key.marker d ck) <> None);
      Contract.put s (Key.chunk d ck) "scrambled!!";
      p "scrambled chunk marker: %s\n"
        (match Contract.get s (Key.marker d ck) with
          | Some b -> (
              match Yojson.Safe.from_string b with
                | `Assoc l -> Yojson.Safe.to_string (List.assoc "computed" l)
                | _ -> "?")
          | None -> "none");
      Contract.put s (Key.chunk d ck) chunk;
      p "rewrite clears it: %b\n" (Contract.get s (Key.marker d ck) = None);
      p "leftover temporaries: %d\n"
        (let n = ref 0 in
         let rec walk dir =
           List.iter
             (fun f ->
               let p = Filename.concat dir f in
               if Names.is_temp_name f && f <> ".tsync-tmp-abc.tmp" then incr n
               else if Fs.is_dir p && not (Fs.kind p = `Link) then walk p)
             (Fs.readdir dir)
         in
         walk root;
         !n);
      let blocked = Filename.concat root "blocked" in
      Fs.write_file_for_test blocked "a file";
      let spaces = Chunk_spaces.create (Filename.concat blocked "root") in
      p "collectable while its root cannot be told: %b\n"
        (Chunk_spaces.collectable spaces);
      Unix.unlink blocked;
      p "collectable once that clears: %b\n" (Chunk_spaces.collectable spaces);
      p "collectable while not yet made, on a local parent: %b\n"
        (Chunk_spaces.collectable
           (Chunk_spaces.create (Filename.concat root "later/root"))));
  Fs.rm_rf root
