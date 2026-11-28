(* Names a filesystem takes for one (conflict-resolution §10, INV-names): a peer
   on a case-sensitive volume keeps names apart that this Mac's case- and
   normalisation-insensitive APFS cannot. *)

open Tsync_core
open Tsync_store
open Tsync_checkout
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-name-clash-%d" (Unix.getpid ()))

let d = Domain_name.v "docs"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_log = (fun _ -> false) }

let run cmd = if Sys.command cmd <> 0 then failwith ("failed: " ^ cmd)

(* The peer's case-sensitive volume. *)
let volume = root ^ "-cs"

let attach () =
  let image = root ^ "-cs.sparseimage" in
  run
    (Printf.sprintf
       "hdiutil create -quiet -size 64m -type SPARSE -fs 'Case-sensitive APFS' \
        -volname tsync-cs %s"
       (Filename.quote image));
  Fs.mkdir_p volume;
  run
    (Printf.sprintf "hdiutil attach -quiet -nobrowse -mountpoint %s %s"
       (Filename.quote volume) (Filename.quote image))

let detach () =
  ignore
    (Sys.command
       (Printf.sprintf "hdiutil detach -quiet -force %s" (Filename.quote volume)));
  Fs.rm_rf volume;
  Fs.unlink_quiet (root ^ "-cs.sparseimage")

let client ~under name : (module Engine.S) =
  let data_dir = Filename.concat under (name ^ "/data") in
  let store = Local.create ~name:"main" (Filename.concat root "store") in
  let composite =
    Composite.create ~domain:d ~data_dir ~owner:true ~poke:ignore ~knowledge
      [{ name = "main"; role = Main; store }]
  in
  let module C = struct
    let domain = d
    let store = Composite.store composite
    let composite = composite
    let versioning = true
    let chunk_size_config = Some 4
    let max_downloads = 4
    let max_chunk_buffers = 4
    let cache_root = Filename.concat under (name ^ "/cache")
    let data_dir = data_dir
    let client_uuid = Identity.client_uuid data_dir
    let client_name = name
    let cache_chunk_size = 8
    let max_cache = None
    let max_uploads = 1
    let read_only = false
    let symlinks = `Keep
    let lazy_tree = false
    let projects_all = false
    let settings _ = (Tuning.default, symlinks)
  end in
  (module Engine.Make (C))

let write (module E : Engine.S) path content =
  E.create path ~exclusive:false;
  E.write path ~off:0 (Bigstring.of_string content);
  E.close path

let drain (module E : Engine.S) = E.drain ~grace:10. ()

let pass (module E : Engine.S) =
  match E.resync () with
    | _ -> ()
    | exception e -> p "pass failed: %s\n" (Printexc.to_string e)

(* Contents are named by the order they were first seen, so the output does not
   depend on digests. *)
let contents = Hashtbl.create 16

let content_tag id =
  match Hashtbl.find_opt contents id with
    | Some t -> t
    | None ->
        let t =
          String.make 1 (Char.chr (Char.code 'a' + Hashtbl.length contents))
        in
        Hashtbl.replace contents id t;
        t

let listing (module E : Engine.S) dir =
  let rec walk dir =
    List.concat_map
      (fun (c : Mirror.child) ->
        let path = Names.join dir c.name in
        match c.kind with
          | `File m ->
              [String.escaped path ^ "=" ^ content_tag (Manifest.content_id m)]
          | `Dir _ -> (String.escaped path ^ "/") :: walk path)
      (List.sort compare (Mirror.list E.mirror dir))
  in
  walk dir

let show name c dir = p "  %-6s %s\n" name (String.concat "  " (listing c dir))

let same what clients dir =
  match List.map (fun c -> listing c dir) clients with
    | first :: rest ->
        p "  %s: every machine holds the same %b\n" what
          (List.for_all (( = ) first) rest)
    | [] -> ()

let settle clients =
  List.iter
    (fun c ->
      pass c;
      drain c)
    clients;
  List.iter pass clients

let () =
  Fs.rm_rf root;
  Fs.mkdir_p root;
  attach ();
  Fun.protect ~finally:detach @@ fun () ->
  Fun.protect ~finally:(fun () -> Test_support.finish root) @@ fun () ->
  (* The disks must disagree, or this tests nothing. *)
  let probe = Filename.concat root "probe" in
  Fs.mkdir_p probe;
  Fs.durable_replace (Filename.concat probe "a") "x";
  Fs.durable_replace (Filename.concat volume "a") "x";
  assert (Sys.file_exists (Filename.concat probe "A"));
  assert (not (Sys.file_exists (Filename.concat volume "A")));
  Rt.run_sync (fun () ->
      let linux = client ~under:volume "linux"
      and mac = client ~under:root "mac"
      and mac2 = client ~under:root "mac2" in
      let all = [linux; mac; mac2] in
      List.iter (fun (module E : Engine.S) -> E.start ~background:false ()) all;
      List.iter pass all;
      let (module L) = linux and (module M) = mac in
      List.iter
        (fun dir -> L.mkdir dir ~exclusive:false)
        ["one"; "two"; "three"; "four"; "five"; "six"; "seven"];
      drain linux;
      List.iter pass all;
      p "== a case change made as a write and a delete, in one entry\n";
      write linux "one/X of Y.md5" "old";
      drain linux;
      pass mac;
      write linux "one/X Of Y.md5" "new";
      L.delete "one/X of Y.md5";
      drain linux;
      pass mac;
      show "mac" mac "one";
      settle all;
      same "one" all "one";
      p "== the same two changes in two entries, an arrival between\n";
      write linux "two/X of Y.md5" "old";
      drain linux;
      pass mac;
      write linux "two/X Of Y.md5" "new";
      drain linux;
      pass mac;
      L.delete "two/X of Y.md5";
      drain linux;
      settle all;
      show "mac" mac "two";
      show "linux" linux "two";
      same "two" all "two";
      p "== two names the peer keeps, two Macs\n";
      write linux "three/Report.txt" "R";
      write linux "three/report.txt" "r";
      drain linux;
      settle all;
      show "mac" mac "three";
      show "linux" linux "three";
      same "three" all "three";
      p "== the Mac held the greater name first\n";
      write linux "four/report.txt" "r";
      drain linux;
      settle all;
      write linux "four/Report.txt" "R";
      drain linux;
      settle all;
      show "mac" mac "four";
      same "four" all "four";
      p "== two folders\n";
      L.mkdir "five/Photos" ~exclusive:false;
      write linux "five/Photos/a.jpg" "1";
      L.mkdir "five/photos" ~exclusive:false;
      write linux "five/photos/b.jpg" "2";
      drain linux;
      settle all;
      show "mac" mac "five";
      same "five" all "five";
      p "== an NFC and an NFD spelling\n";
      (* Every APFS, the case-sensitive one too, takes the two for one, so no
         peer here can keep both: the detection is shown on the Mac's tree. *)
      write mac "six/caf\xc3\xa9.txt" "nfc";
      (match M.create "six/cafe\xcc\x81.txt" ~exclusive:false with
        | () -> p "  created\n"
        | exception Fail.E { kind = Exists; _ } -> p "  refused: EXISTS\n");
      p "  the NFD spelling reads %s\n"
        (match Mirror.file M.mirror "six/cafe\xcc\x81.txt" with
          | `Absent -> "nothing"
          | _ -> "an entry");
      p "== a case-only rename keeps the file id\n";
      write mac "seven/notes.txt" "n";
      drain mac;
      settle all;
      let id = Mirror.file_id M.mirror "seven/notes.txt" in
      M.rename ~src:"seven/notes.txt" ~dst:"seven/Notes.txt" ~exclusive:false;
      p "  mac: id kept %b\n"
        (id <> None && Mirror.file_id M.mirror "seven/Notes.txt" = id);
      drain mac;
      settle all;
      let id = Mirror.file_id M.mirror "seven/Notes.txt" in
      L.rename ~src:"seven/Notes.txt" ~dst:"seven/NOTES.txt" ~exclusive:false;
      drain linux;
      settle all;
      p "  arrived: id kept %b\n"
        (id <> None && Mirror.file_id M.mirror "seven/NOTES.txt" = id);
      show "mac" mac "seven";
      same "seven" all "seven";
      p "== a local create beside a name the filesystem takes for it\n";
      match M.create "three/REPORT.txt" ~exclusive:false with
        | () -> p "  created\n"
        | exception Fail.E { kind = Exists; _ } -> p "  refused: EXISTS\n")
