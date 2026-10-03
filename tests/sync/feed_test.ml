(* The change feed's anchors (08 §2.5, §3.6) and the applied log's retention
   under the feed watermark (wal-and-journal §4.8). *)

open Tsync_core
open Tsync_store
open Tsync_checkout
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-feed-%d" (Unix.getpid ()))

let d = Domain_name.v "docs"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_journal = (fun _ -> false) }

let data_dir name = Filename.concat root (name ^ "/data")

let client name : (module Engine.S) =
  let data_dir = data_dir name in
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
    let cache_root = Filename.concat root (name ^ "/cache")
    let data_dir = data_dir
    let client_uuid = Identity.client_uuid data_dir
    let client_name = name
    let cache_chunk_size = 8
    let max_cache = None
    let max_uploads = 1
    let read_only = false
    let symlinks = `Keep
    let lazy_tree = false
  end in
  (module Engine.Make (C))

(* Entry keys, generations and file ids print as numbered placeholders. *)
let aliases = Hashtbl.create 16

let alias prefix s =
  match Hashtbl.find_opt aliases s with
    | Some a -> a
    | None ->
        let a = Printf.sprintf "<%s%d>" prefix (Hashtbl.length aliases + 1) in
        Hashtbl.replace aliases s a;
        a

let show_anchor a =
  match String.index_opt a '|' with
    | Some i ->
        let gen = String.sub a 0 i
        and entry = String.sub a (i + 1) (String.length a - i - 1) in
        (if gen = "" then "" else alias "gen" gen)
        ^ "|"
        ^ if entry = "" then "" else alias "entry" entry
    | None -> a

let op_name = function
  | Op.Put { path; _ } -> "put " ^ path
  | Delete path -> "delete " ^ path
  | Mkdir { path; _ } -> "mkdir " ^ path
  | Rmdir { path; _ } -> "rmdir " ^ path
  | Rename { src; dst; _ } -> "rename " ^ src ^ "->" ^ dst

let feed label (module E : Engine.S) anchor =
  match E.changes_since anchor ~limit:100 with
    | `Stale ->
        p "  %s: stale\n" label;
        None
    | `Page (cursor, more, ops) ->
        p "  %s: cursor %s more=%b\n" label (show_anchor cursor) more;
        List.iter
          (fun (o : Applied.op) ->
            p "    %-26s %s\n" (op_name o.op)
              (match o.fid with Some id -> alias "file" id | None -> ""))
          ops;
        Some cursor

let write (module E : Engine.S) path content =
  E.create path ~exclusive:false;
  E.write path ~off:0 (Bigstring.of_string content);
  E.close path

let drain (module E : Engine.S) = E.drain ~grace:10. ()

let pass (module E : Engine.S) =
  (match E.apply_pass () with
    | _ -> ()
    | exception e -> p "pass failed: %s\n" (Printexc.to_string e));
  match E.bridge () with
    | Engine.Hold _ -> ignore (E.resync ())
    | Incremental -> ()

let watermark name =
  match
    Fs.read_file_opt
      (Filename.concat (data_dir name)
         ("feed-watermark-" ^ Domain_name.to_string d))
  with
    | Some s -> (
        match String.split_on_char ' ' s with
          | [entry; _] ->
              if entry = "" then "before every entry" else alias "entry" entry
          | _ -> "torn")
    | None -> "none"

let dropped name =
  Fs.exists
    (Filename.concat (data_dir name)
       ("feed-dropped-" ^ Domain_name.to_string d))

let () =
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let a = client "A" and b = client "B" in
      let (module A) = a and (module B) = b in
      A.start ~poll_journal:false ();
      B.start ~poll_journal:false ();
      pass a;
      pass b;
      p "== a consumer's first anchor sets the watermark\n";
      p "  watermark before: %s\n" (watermark "B");
      let baseline = B.cursor () in
      p "  cursor %s, watermark %s\n" (show_anchor baseline) (watermark "B");
      p "== a peer's changes reach B's feed, files named by B's ids\n";
      write a "x.txt" "one";
      A.mkdir "dir" ~exclusive:false;
      drain a;
      A.rename ~src:"x.txt" ~dst:"dir/y.txt" ~exclusive:false;
      drain a;
      pass b;
      let cursor = Option.get (feed "from the baseline" b baseline) in
      p "  watermark: %s\n" (watermark "B");
      ignore (feed "from its cursor" b cursor);
      p "  watermark: %s\n" (watermark "B");
      p "== a rebuild keeps anchors valid\n";
      ignore (B.rebuild ());
      ignore (feed "from the cursor after a rebuild" b cursor);
      p "== a new generation makes every anchor stale\n";
      B.stamp_generation ();
      p "  watermark: %s\n" (watermark "B");
      ignore (feed "from the old cursor" b cursor);
      let fresh = B.cursor () in
      p "  new cursor %s\n" (show_anchor fresh);
      p "== retention: an old shard is kept while the watermark names it\n";
      let applied = Filename.concat (Mirror.root B.mirror) "applied" in
      let old = Entry_key.make ~ms:1_600_000_000_000L ~client:"c" in
      Fs.append_durable
        (Filename.concat applied "2020-09.log")
        ("\n" ^ Entry_key.to_string old ^ "\t[]");
      let mark = Filename.concat (data_dir "B") "feed-watermark-docs" in
      Fs.durable_replace mark
        (Printf.sprintf "%s %.0f" (Entry_key.to_string old)
           (Unix.gettimeofday () *. 1000.));
      let n = B.prune_applied () in
      p "  pruned with the watermark on it: %d, dropped: %b\n" n (dropped "B");
      p "== a watermark idle past its age holds nothing\n";
      Fs.durable_replace mark
        (Printf.sprintf "%s %.0f" (Entry_key.to_string old)
           ((Unix.gettimeofday () -. (200. *. 86400.)) *. 1000.));
      let n = B.prune_applied () in
      p "  pruned: %d, dropped: %b\n" n (dropped "B");
      let gen = String.sub fresh 0 (String.index fresh '|') in
      ignore
        (feed "an anchor naming the dropped entry" b
           (gen ^ "|" ^ Entry_key.to_string old));
      ignore (feed "an empty anchor once a shard was dropped" b (gen ^ "|")));
  Fs.rm_rf root
