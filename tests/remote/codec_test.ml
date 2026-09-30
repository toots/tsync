open Tsync_core
open Tsync_remote

let p fmt = Printf.printf fmt

let hexdump s =
  let n = String.length s in
  let rec line o =
    if o < n then (
      let l = min 16 (n - o) in
      p "%04x  " o;
      for i = 0 to 15 do if i < l then p "%02x " (Char.code s.[o + i]) else p "   " done;
      p " ";
      String.iter (fun c -> p "%c" (if c >= ' ' && c <= '~' then c else '.')) (String.sub s o l);
      p "\n";
      line (o + 16))
  in
  line 0

let () =
  p "== manifest example (02 §2.6)\n";
  let ck = Chunk_key.of_body "hello world" in
  let m = Manifest.make ~name:"hello.txt" ~size:11 ~mtime:1759140000.5 ~chunk_size:8388608 [ck] in
  p "h = %s-%s, %d bytes\n" m.h1 m.h2 (String.length m.body);
  hexdump m.body;
  p "empty regular file names the empty chunk once; h1 = %s\n"
    (Manifest.make ~name:"e" ~size:0 ~mtime:0. ~chunk_size:8388608 [Chunk_key.empty]).h1;
  let l = Manifest.symlink ~name:"l" ~mtime:0. "target" in
  p "symlink: count %d, size %d, link %s\n" l.count l.size (Option.get l.link);
  p "\n== readers refuse\n";
  let b = m.body in
  List.iter
    (fun (what, body) -> p "%-22s %s\n" what (if Manifest.decode body = None then "refused" else "ACCEPTED"))
    [
      ("short", String.sub b 0 71);
      ("other magic", "tsyncm04" ^ String.sub b 8 (String.length b - 8));
      ("negative size", (let x = Bytes.of_string b in Bytes.set_int64_le x 8 (-1L); Bytes.to_string x));
      ("length mismatch", b ^ "x");
    ];
  p "renamed records the new leaf: %s\n" (Manifest.rename m "other.txt").name;
  p "\n== folder bodies (02 §2.7–2.9)\n";
  let id = Folder_id.v "3f2a9c1b7d4e-1a" in
  p "%s\n" (Folder.marker_body { name = "Photos"; id });
  p "%s\n" (Folder.anchor_body { parent = Folder_id.root; aname = "Photos" });
  p "%s\n" (Folder.trash_body { name = "Photos"; id } ~path:"Archive/Photos");
  List.iter
    (fun body ->
      p "%-48s %s\n" body
        (match Folder.classify_marker body with
          | `Marker (m, _) -> "marker " ^ Folder_id.to_string m.id
          | `Unclassifiable -> "unclassifiable"
          | `Not_marker -> "not a marker"))
    [{|{"id":"3f2a9c1b7d4e-1a","dir":true,"x":1}|}; {|{"dir":true,"name":"a","id":""}|}; {|{"parent":".tsync-root","name":"a"}|}];
  p "\n== keys\n";
  let d = Domain_name.v "photos" in
  p "%s\n" (Key.to_string (Key.child d Folder_id.root "Photos"));
  p "%s\n" (Key.to_string (Key.anchor d id));
  p "%s\n" (Key.to_string (Key.child d id "hello.txt"));
  p "%s\n" (Key.to_string (Key.chunk d ck));
  p "marker of chunk: %s\n" (match Key.marker_of (Key.chunk d ck) with Some k -> Key.to_string k | None -> "none");
  p "marker of outgoing chunk: %s\n" (match Key.marker_of (Key.chunk_from d ck) with Some k -> Key.to_string k | None -> "none");
  p "run name of 1755300000.5: %s\n" (Key.run_name 1755300000.5);
  List.iter
    (fun k ->
      p "%-40s %s\n" k
        (match Key.parse_discard_job (Key.v k) with Some (d, r, s) -> Printf.sprintf "%s/%s/%s" (Domain_name.to_string d) r s | None -> "not a job"))
    ["tsync/gc-jobs/My Files/1755300000500/a3f"; "tsync/gc-jobs/d/000"; "tsync/gc-jobs/d/1/zz"]
