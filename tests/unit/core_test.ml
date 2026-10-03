open Tsync_core

let p fmt = Printf.printf fmt

let bytes_pattern n =
  String.init n (fun i -> Char.chr (((31 * i) + 7) land 255))

(* The child of the jitter case below: one delay, and nothing else. *)
let () =
  if Array.length Sys.argv > 1 && Sys.argv.(1) = "jitter" then (
    p "%.17g\n" (Retry.delay 3);
    exit 0)

let () =
  p "== hashes (01 §3.1)\n";
  List.iter
    (fun (name, s) ->
      p "%-14s %s %s\n" name
        (Xxh.hex16 (Xxh.string s))
        (Xxh.hex16 (Xxh.string ~seed:1L s)))
    [
      ("\"\"", "");
      ("hello world", "hello world");
      ("8 MiB pattern", bytes_pattern 8388608);
    ];
  p "streaming equals one-shot:";
  List.iter
    (fun len ->
      let s = bytes_pattern len in
      let ok =
        List.for_all
          (fun step ->
            let st = Xxh.dual_create () in
            let rec go o =
              if o < len then (
                Xxh.dual_update_string st s o (min step (len - o));
                go (o + step))
            in
            go 0;
            Xxh.dual_digest st = Xxh.dual s)
          [1; 16; 240; 1048576]
      in
      p " %d:%b" len ok)
    [0; 1; 16; 17; 128; 129; 240; 241; 2600; 1048576; 1048577];
  p "\n";
  List.iter
    (fun s -> p "dual %-10S %s\n" s (Xxh.dual s))
    ["hello world"; ""; "img.jpg"; "hello.txt"; "Photos"];
  p "\n== chunk keys\n";
  List.iter
    (fun s -> p "%-36S %b\n" s (Names.is_chunk_key s))
    [
      "d447b1ea40e6988b-b7aeb52a10fdaf2d";
      "D447b1ea40e6988b-b7aeb52a10fdaf2d";
      "d447b1ea40e6988b_b7aeb52a10fdaf2d";
      "ab";
    ];
  p "shard of ab: %s\n" (Names.shard "ab");
  p "\n== keys and domain names (01 §2.1–2.2)\n";
  List.iter
    (fun k -> p "key %-14S %b\n" k (Names.valid_key k))
    ["a/b"; ""; "/a"; "a/"; "a//b"; "a/./b"; "a/../b"; "a\000b"];
  List.iter
    (fun (d, local) ->
      p "domain %-10S local=%-5b %b\n" d local
        (Names.valid_domain_name ~local_store:local d))
    [
      ("shares", false);
      ("gc-jobs", false);
      ("a/b", false);
      ("..", false);
      (".tsync-x", false);
      ("SHARES", true);
      ("SHARES", false);
      ("Family Photos", false);
      ("chunks", false);
    ];
  List.iter
    (fun id -> p "folder id %-36S %b\n" id (Names.valid_folder_id id))
    [
      "3f2a9c1b7d4e";
      "9f3a1c0428b6d5e7";
      "0123456789abcdef0123456789abcdef";
      "3f2a9c1b7d4e-1a";
      "Photos";
      "..";
    ];
  p "\n== item references (01 §2.7)\n";
  List.iter
    (fun s ->
      p "%-24S %s\n" s
        (match Names.parse_ref s with
          | Ok r -> Names.ref_to_string r
          | Error () -> "malformed"))
    [
      "root";
      "d:.tsync-root";
      "f:3f2a9c1b7d4e-1a/a:b";
      "f:3f2a9c1b7d4e-1a/a/b";
      "d:";
      "f:3f2a9c1b7d4e-1a/";
      "f:/x";
      "d:..";
      "d:Photos";
      "tsync/d/manifests/x";
      "i:6c1e0b9a2f4d47e8a3b5c7d9e1f20384";
      "i:6C1E0B9A2F4D47E8A3B5C7D9E1F20384";
      "i:6c1e0b9a";
      "i:";
    ];
  p "\n== temporary names (01 §2.9)\n";
  List.iter
    (fun n ->
      p "%-24S ours=%-5b owner=%s\n" n (Names.is_temp_name n)
        (match Names.temp_owner n with
          | Some p -> string_of_int p
          | None -> "-"))
    [
      ".tsync-tmp-1-2.tmp";
      ".tsync-tmp-9f3a0c.tmp";
      ".tsync-tmp-scratch.tmp";
      ".syncthing.X.mkv.tmp";
      "x.tmp";
      ".tsync-tmp-1-2.txt";
      "my.tsync-tmp-1-2.tmp";
    ];
  p "escape %S -> %s\n" "a:b" (Names.escape "a:b");
  p "\n== pieces (01 §3.4), cs = 8\n";
  List.iter
    (fun (off, len, count) ->
      p "[%d,%d) count %d:" off (off + len) count;
      List.iter
        (fun (x : Chunking.piece) ->
          p " #%d[%d,%d)@%d" x.index x.off (x.off + x.len) x.buf_off)
        (Chunking.pieces ~cs:8 ~count ~off ~len);
      p "\n")
    [(6, 4, 3); (12, 16, 2); (16, 8, 2); (0, 0, 2)];
  p "\n== glob (01 §17)\n";
  List.iter
    (fun (pat, paths) ->
      List.iter
        (fun path -> p "%-14S %-14S %b\n" pat path (Glob.matches pat path))
        paths)
    [
      ( "**/.git",
        [".git"; "a/.git"; "a/b/.git"; "foo.git"; "a/repo.git"; "a/b/c"] );
      ("**/node_modules", ["a/my_node_modules"]);
      ( "src/**/*.ml",
        ["src/foo.ml"; "src/a/b/foo.ml"; "src/a/b/foo.c"; "srcx/foo.ml"] );
      ("a/**", ["a/b"; "a/b/c"; "a"]);
      ("*.ml", ["foo.ml"; "dir/foo.ml"]);
      ("fo?", ["foo"; "fo"; "fo/"]);
      ("a**b", ["axyb"; "ax/yb"]);
      ("lost+found", ["lost+found"]);
      ("foo.bar", ["fooXbar"]);
      ("", [""; "x"]);
      ("*", [""; "abc"]);
      ("**", [""; "a/b/c"]);
    ]

let () =
  p "\n== zip (01 §13)\n";
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-zip-%d" (Unix.getpid ()))
  in
  Fs.rm_rf dir;
  Fs.mkdir_p dir;
  let path = Filename.concat dir "a.zip" in
  let oc = open_out_bin path in
  let z = Zip.create (fun b -> output_string oc (Bigstring.to_string b)) in
  let binary = String.init 300 (fun i -> Char.chr (i land 255)) in
  let members =
    [
      ("d/text.txt", "hello zip\n");
      ("d/bin", binary);
      ("d/empty", "");
      ("d/héllo ✓.txt", "utf8\n");
    ]
  in
  Zip.add_dir z ~name:"d" ~mtime:0.;
  List.iter
    (fun (name, body) ->
      Zip.add_file z ~name ~mtime:0. (fun feed ->
          feed (Bigstring.of_string body)))
    members;
  Zip.finish z;
  close_out oc;
  let test =
    Sys.command
      (Printf.sprintf "cd %s && unzip -tqq a.zip >/dev/null 2>&1"
         (Filename.quote dir))
  in
  let extract =
    Sys.command
      (Printf.sprintf "cd %s && unzip -qq a.zip >/dev/null 2>&1"
         (Filename.quote dir))
  in
  p "unzip -t: %s, extract: %s\n"
    (if test = 0 then "ok" else "FAIL")
    (if extract = 0 then "ok" else "FAIL");
  List.iter
    (fun (name, body) ->
      let got =
        try Fs.read_file (Filename.concat dir name) with _ -> "<missing>"
      in
      p "%-16s %s\n" name (if got = body then "byte-exact" else "DIFFERENT"))
    members;
  Fs.rm_rf dir

let () =
  p "\n== key areas: a domain may be named like an area\n";
  let ck = Chunk_key.of_body "x" in
  let show_parts = function
    | Some (d, c) ->
        Printf.sprintf "%s %b" (Domain_name.to_string d) (Chunk_key.equal c ck)
    | None -> "none"
  in
  List.iter
    (fun name ->
      let d = Domain_name.v name in
      let outcome f = try f () with e -> "raises " ^ Printexc.to_string e in
      p
        "%-11s chunk %s; outgoing %s; marker %b; reference %s; version %s; \
         manifest marker %b\n"
        name
        (outcome (fun () -> show_parts (Key.chunk_parts (Key.chunk d ck))))
        (outcome (fun () ->
             show_parts (Key.outgoing_chunk (Key.chunk_from d ck))))
        (Key.marker_of (Key.chunk d ck) = Some (Key.marker d ck))
        (outcome (fun () ->
             Option.fold ~none:"none" ~some:Domain_name.to_string
               (Key.domain_of_reference (Key.child d Folder_id.root "f"))))
        (outcome (fun () ->
             Option.fold ~none:"none" ~some:Domain_name.to_string
               (Key.domain_of_reference (Key.version d ~group:"g/h" ~ns:1L))))
        (try Key.marker_of (Key.child d Folder_id.root "f") = None
         with _ -> false))
    ["d"; "chunks"; "manifests"; "versions"; "chunks.from"]

let () =
  p "\n== a mount point, its parent resolved\n";
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-mnt-%d" (Unix.getpid ()))
  in
  Fs.rm_rf dir;
  Fs.mkdir_p (Filename.concat dir "real");
  Unix.symlink (Filename.concat dir "real") (Filename.concat dir "link");
  let expected = Filename.concat (Unix.realpath dir) "real/Drive" in
  List.iter
    (fun given ->
      p "%-24s %b\n" given
        (Fs.resolve_parent (Filename.concat dir given) = expected))
    ["real/Drive"; "real/Drive/"; "real/./Drive"; "real//Drive"; "link/Drive"];
  p "%-24s %s\n" "/" (Fs.resolve_parent "/");
  Fs.rm_rf dir

let () =
  p "\n== retry jitter differs between processes\n";
  let draw () =
    let ic =
      Unix.open_process_in (Filename.quote Sys.executable_name ^ " jitter")
    in
    let l = input_line ic in
    ignore (Unix.close_process_in ic);
    l
  in
  let first = draw () in
  p "two processes drew the same first delay: %b\n" (first = draw ())

let () =
  p "\n== a stall is counted for the uplink governor, another failure not\n";
  Rt.run_sync (fun () ->
      let tally raise_once =
        let health = Health.create "store" and tried = ref false in
        Retry.ladder ~health ~op:"read" (fun () ->
            if not !tried then (
              tried := true;
              raise_once ()));
        Health.timeouts health
      in
      p "a wait that heard nothing: %d; a refused connection: %d\n"
        (tally (fun () -> raise Rt.Timeout))
        (tally (fun () -> Fail.raise_ Fail.Link "refused")))

let () =
  p "\n== keyed locks keep no entry for an idle key\n";
  Rt.run_sync (fun () ->
      let locks = Keyed_locks.create () in
      List.iter
        (fun i -> Keyed_locks.with_key locks (string_of_int i) ignore)
        (List.init 1000 Fun.id);
      p "after locking 1000 keys once: %d entries\n" (Keyed_locks.size locks);
      let inside = Atomic.make 0 and overlapped = Atomic.make false in
      let hold () =
        Keyed_locks.with_key locks "k" (fun () ->
            if Atomic.fetch_and_add inside 1 > 0 then Atomic.set overlapped true;
            Rt.sleep 0.05;
            Atomic.decr inside)
      in
      let others = List.init 3 (fun _ -> Rt.async hold) in
      hold ();
      List.iter Rt.Promise.await others;
      p "four holders of one key overlapped: %b; entries after: %d\n"
        (Atomic.get overlapped) (Keyed_locks.size locks);
      let before = Keyed_locks.generation locks "k" in
      Keyed_locks.with_key locks "k" ignore;
      p "generation unchanged by a hold: %b\n"
        (Keyed_locks.generation locks "k" = before);
      Keyed_locks.bump locks "k";
      Keyed_locks.with_key locks "k" ignore;
      p "changed by a bump: %b; a bumped key keeps its entry: %d\n"
        (Keyed_locks.generation locks "k" <> before)
        (Keyed_locks.size locks))

let () =
  p "\n== a set of chunk keys, packed\n";
  let key i = Chunk_key.of_body (string_of_int i) in
  let set = Chunk_set.create () in
  let n = 100_000 in
  for i = 0 to n - 1 do
    Chunk_set.add set (key i)
  done;
  Chunk_set.add set (key 0);
  p "added %d keys, one twice: %d held\n" n (Chunk_set.cardinal set);
  let found = ref 0 in
  for i = 0 to n - 1 do
    if Chunk_set.mem set (key i) then incr found
  done;
  p "found: %d; a key never added: %b\n" !found (Chunk_set.mem set (key n));
  (* A table of key strings holds the same in about 8.5 MB. *)
  p "held in under 4 MB: %b\n"
    (Obj.reachable_words (Obj.repr set) * (Sys.word_size / 8) < 4_000_000);
  p "listed back: %b\n"
    (List.sort compare (Chunk_set.elements set)
    = List.sort compare (List.init n key));
  Chunk_set.remove set (key 7);
  p "removed one: %b, %d held\n"
    (not (Chunk_set.mem set (key 7)))
    (Chunk_set.cardinal set);
  let shard = Chunk_key.shard (key 1) in
  let in_shard =
    List.length
      (List.filter
         (fun i -> Chunk_key.shard (key i) = shard && i <> 7)
         (List.init n Fun.id))
  in
  Chunk_set.clear_shard set shard;
  p "cleared a shard: its key gone %b, the count follows %b\n"
    (not (Chunk_set.mem set (key 1)))
    (Chunk_set.cardinal set = n - 1 - in_shard);
  let overflowed = ref 0 in
  let small =
    Chunk_set.create ~max:10 ~on_overflow:(fun () -> incr overflowed) ()
  in
  for i = 0 to 24 do
    Chunk_set.add small (key i)
  done;
  p "25 keys into a set of at most 10: %d held, emptied %d times\n"
    (Chunk_set.cardinal small) !overflowed
