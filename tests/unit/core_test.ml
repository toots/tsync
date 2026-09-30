open Tsync_core

let p fmt = Printf.printf fmt

let bytes_pattern n =
  String.init n (fun i -> Char.chr (((31 * i) + 7) land 255))

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
  let z = Zip.create (output_string oc) in
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
    (fun (name, body) -> Zip.add_file z ~name ~mtime:0. (fun feed -> feed body))
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
