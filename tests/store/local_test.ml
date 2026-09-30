open Tsync_core
open Tsync_store

let p = Contract.p

let () =
  let root = Filename.concat (Filename.get_temp_dir_name ()) (Printf.sprintf "tsync-local-%d" (Unix.getpid ())) in
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
      p "listing: %s\n" (String.concat "," (List.map (fun (e : Store.entry) -> Key.rel (Key.prefix "tsync/d/l/") e.key) (s.list_prefix (Key.prefix "tsync/d/l/"))));
      Unix.symlink "/etc" (Filename.concat root "tsync/d/esc");
      p "read through a planted link: %s\n" (Contract.kind_of (fun () -> s.get_opt (Key.v "tsync/d/esc/passwd")));
      p "write through a planted link: %s\n" (Contract.kind_of (fun () -> s.put (Key.v "tsync/d/esc/x") "x"));
      let chunk = "hello world" in
      let ck = Chunk_key.of_body chunk in
      let d = Domain_name.v "d" in
      s.put (Key.chunk d ck) chunk;
      p "good chunk marker: %b\n" (s.get_opt (Key.marker d ck) <> None);
      s.put (Key.chunk d ck) "scrambled!!";
      p "scrambled chunk marker: %s\n"
        (match s.get_opt (Key.marker d ck) with
          | Some b -> (match Yojson.Safe.from_string b with `Assoc l -> Yojson.Safe.to_string (List.assoc "computed" l) | _ -> "?")
          | None -> "none");
      s.put (Key.chunk d ck) chunk;
      p "rewrite clears it: %b\n" (s.get_opt (Key.marker d ck) = None);
      p "leftover temporaries: %d\n"
        (let n = ref 0 in
         let rec walk dir = List.iter (fun f -> let p = Filename.concat dir f in if Names.is_temp_name f && f <> ".tsync-tmp-abc.tmp" then incr n else if Fs.is_dir p && not (Fs.kind p = `Link) then walk p) (Fs.readdir dir) in
         walk root; !n));
  Fs.rm_rf root
