(* Expiry and purge (spec algorithms/gc.md §4, §10 "Retention", "Purge"): what
   each deletes on a local main, first as a dry run, then applied. *)

open Tsync_core
open Tsync_store
open Tsync_gc

let p fmt = Printf.printf fmt
let d = Domain_name.v "d"
let day = 86400.

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-retention-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  let store_root = Filename.concat root "store" in
  let main = Local.create ~name:"main" store_root
  and replica = Local.create ~name:"replica" (Filename.concat root "replica") in
  let now = Unix.gettimeofday () in
  let cutoff = now -. (10. *. day) in
  let ids =
    [
      ("live", "0000000000a1-1");
      ("trashed", "0000000000a2-1");
      ("sub", "0000000000a3-1");
      ("moved", "0000000000a4-1");
      ("recent", "0000000000a5-1");
      ("orphan", "0000000000a6-1");
    ]
  in
  let id n = Folder_id.v (List.assoc n ids) in
  let labels = Hashtbl.create 8 in
  let alias s =
    match Hashtbl.find_opt labels s with
      | Some l -> l
      | None ->
          List.fold_left
            (fun s (n, i) -> Text.replace_all ~sub:i ~by:("<" ^ n ^ ">") s)
            s ids
          |> Text.replace_all ~sub:"tsync/d/" ~by:""
  in
  let put ?(age = 0.) key body =
    main.put key (Bigstring.of_string body);
    let t = now -. (age *. day) in
    Unix.utimes (Filename.concat store_root (Key.to_string key)) t t
  in
  let marker parent name child =
    put (Key.child d parent name) (Folder.marker_body { name; id = id child });
    put (Key.anchor d (id child)) (Folder.anchor_body { parent; aname = name })
  in
  let empty name =
    (Manifest.make ~name ~size:0 ~mtime:0. ~chunk_size:Chunking.chunk_size_min
       [Chunk_key.of_body ""])
      .body
  in
  let file parent name = put (Key.child d parent name) (empty name) in
  let trash ?(age = 30.) n path entry =
    put ~age (Key.trash_entry d entry)
      (Folder.trash_body { name = n; id = id n } ~path)
  in
  Rt.run_sync (fun () ->
      main.put (Key.chunk d (Chunk_key.of_body "")) Bigstring.empty;
      marker Folder_id.root "live" "live";
      file (id "live") "keep.txt";
      marker (id "trashed") "sub" "sub";
      file (id "trashed") "f.txt";
      file (id "sub") "g.txt";
      marker (id "trashed") "moved" "moved";
      put
        (Key.anchor d (id "moved"))
        (Folder.anchor_body { parent = Folder_id.root; aname = "moved" });
      file (id "moved") "h.txt";
      put
        (Key.anchor d (id "trashed"))
        (Folder.anchor_body { parent = Folder_id.trash; aname = "trashed" });
      trash "trashed" "trashed" "e1";
      put
        (Key.anchor d (id "recent"))
        (Folder.anchor_body { parent = Folder_id.trash; aname = "recent" });
      trash "recent" "recent" "e2";
      trash ~age:1. "recent" "recent" "e3";
      trash "live" "live" "e4";
      trash ~age:1. "live" "live" "e5";
      trash "orphan" "orphan" "e6";
      List.iter
        (fun (group, days) ->
          let key =
            Key.version d ~group
              ~ns:(Int64.of_float ((now -. (days *. day)) *. 1e9))
          in
          Hashtbl.replace labels (Key.to_string key)
            (Printf.sprintf "version of %.0f days ago in %s" days group);
          put key (empty "v"))
        [
          ("0000000000a1-1/h", 40.);
          ("0000000000a1-1/h", 5.);
          ("0000000000a7-1/gone", 50.);
        ];
      let entry days =
        Tsync_sync.Entry_key.make
          ~ms:(Int64.of_float ((now -. (days *. day)) *. 1000.))
          ~client:"c"
      in
      List.iter
        (fun days ->
          let key = Tsync_sync.Entry_key.journal_key d (entry days) in
          Hashtbl.replace labels (Key.to_string key)
            (Printf.sprintf "journal entry of %.0f days ago" days);
          put key "[]")
        [60.; 45.; 20.; 1.];
      put (Key.cursor d) (Tsync_sync.Entry_key.to_string (entry 60.));
      let share token body = put (Option.get (Key.share token)) body in
      share "aa01"
        (Printf.sprintf {|{"v":1,"expires":%.0f,"domain":"d","type":"file"}|}
           (now -. day));
      put ~age:1. (Key.v "tsync/shares/cache/aa01.data") "zip";
      share "aa02"
        (Printf.sprintf {|{"v":1,"expires":%.0f,"domain":"d","type":"file"}|}
           (now +. day));
      share "aa03"
        (Printf.sprintf {|{"v":1,"expires":%.0f,"domain":"e","type":"file"}|}
           (now -. day));
      share "aa04" "garbage";
      replica.put
        (Option.get (Key.share "aa05"))
        (Bigstring.of_string
           (Printf.sprintf {|{"v":1,"expires":%.0f,"domain":"d","type":"file"}|}
              (now -. day)));
      put ~age:30. (Key.v "tsync/shares/cache/0123-4567.data") "old";
      put ~age:30. (Option.get (Key.share_preview "aa01")) "jpeg";
      put ~age:30. (Option.get (Key.share_preview "aa02")) "jpeg";
      put (Option.get (Key.share_preview "aa09")) "jpeg";
      let share_read = ref false in
      let watched =
        {
          main with
          get_opt =
            (fun k ->
              if Key.under Key.shares k then share_read := true;
              main.get_opt k);
        }
      in
      let composite =
        Composite.create ~domain:d
          ~data_dir:(Filename.concat root "data")
          ~owner:true ~poke:ignore
          ~knowledge:
            {
              Composite.is_index = (fun _ -> false);
              is_journal = (fun _ -> false);
            }
          [
            { name = "main"; role = Main; store = watched };
            { name = "replica"; role = Replica; store = replica };
          ]
      in
      let module C = struct
        let domain = d
        let store = Composite.store composite
        let composite = composite
        let versioning = true
        let chunk_size_config = None
        let max_downloads = 4
        let max_chunk_buffers = 4
      end in
      let module R = Retention.Make (C) in
      let listing () =
        List.map
          (fun (e : Store.entry) -> Key.to_string e.key)
          (main.list_prefix Key.root)
      in
      let show (r : Retention.report) =
        p "trash %d, versions %d, journal %d, shares %d\n"
          r.counts.trash_deleted r.counts.versions_deleted
          r.counts.journal_deleted r.counts.shares_deleted;
        List.iter
          (fun k -> p "  delete %s\n" (alias (Key.to_string k)))
          r.deleted;
        List.iter
          (fun i ->
            p "  skipped, trashed recently: %s\n"
              (alias (Folder_id.to_string i)))
          r.skipped_recent;
        List.iter
          (fun k ->
            p "  unparseable share left: %s\n" (alias (Key.to_string k)))
          r.unparseable_shares
      in
      p "== purge on demand\n";
      let purge ?cancelled path =
        match R.purge ?cancelled path with
          | Purged n -> Printf.sprintf "would purge %d objects" n
          | Not_in_trash -> "not in trash"
          | Live_elsewhere -> "live elsewhere"
          | Stopped reason -> "stopped: " ^ reason
      in
      p "never trashed: %s\n" (purge "nowhere");
      p "anchored live: %s\n" (purge "live");
      p "trashed: %s\n" (purge "trashed");
      p "trashed, cancelled: %s\n" (purge ~cancelled:(Fun.const true) "trashed");
      p "\n== expire, dry run (cutoff 10 days ago)\n";
      let before = listing () in
      show (R.expire ~now ~cutoff ());
      p "dry run changed nothing: %b\n" (listing () = before);
      p "\n== expire, cancelled before it starts\n";
      let r = R.expire ~cancelled:(Fun.const true) ~now ~cutoff () in
      show r;
      p "cancelled: %b\n" r.cancelled;
      p "\n== expire, cancelled at the first share read\n";
      share_read := false;
      (match R.expire ~cancelled:(fun () -> !share_read) ~now ~cutoff () with
        | r ->
            p "ran to the end: shares %d, cancelled %b\n"
              r.counts.shares_deleted r.cancelled
        | exception Fail.E f -> p "stopped: %s\n" f.reason);
      p "\n== expire, applied\n";
      show (R.expire ~apply:true ~now ~cutoff ());
      let dir rel =
        Fs.is_dir (Filename.concat store_root ("tsync/d/versions/" ^ rel))
      in
      p "group directories: kept %b, emptied %b, its folder %b\n"
        (dir "0000000000a1-1/h")
        (dir "0000000000a7-1/gone")
        (dir "0000000000a7-1");
      p "share held only by the replica, expired there: %b\n"
        (replica.head_opt (Option.get (Key.share "aa05")) = None);
      p "left on the store:\n";
      List.iter (fun k -> p "  %s\n" (alias k)) (listing ()));
  Fs.rm_rf root
