open Tsync_core
open Tsync_sync
open Tsync_checkout

let p fmt = Printf.printf fmt

let () =
  p "== entry keys (03 §2.2)\n";
  List.iter
    (fun s ->
      p "%-56S %s\n" s
        (match Entry_key.parse s with
          | Some k -> Entry_key.to_string k ^ " month " ^ Entry_key.month k
          | None -> "not a key"))
    [
      "1788134400000-3f9a0c1b2d4e5f60718293a4b5c6d7e8";
      "tsync/photos/journal/2026-09/1788134400000-abc";
      "2026-08";
      "178813440000-abc";
      ".tsync-tmp-1-2.tmp";
    ];
  p "\n== ops (03 §2.3)\n";
  let ops =
    [
      Op.Put { path = "photos/one.jpg"; size = 1024; base = None };
      Op.Put
        { path = "photos/one.jpg"; size = 2048; base = Some "8f3a0c1b2d4e5f60" };
      Op.Delete "photos/two.jpg";
      Op.Mkdir { path = "photos"; id = Some (Folder_id.v "3f9a0c1b2d4e-40a") };
      Op.Rmdir { path = "photos"; id = Some (Folder_id.v "3f9a0c1b2d4e-40a") };
      Op.Rename
        {
          dst = "photos/two.jpg";
          src = "photos/one.jpg";
          is_dir = false;
          size = Some 1024;
          id = None;
        };
      Op.Rename
        {
          dst = "pics";
          src = "photos";
          is_dir = true;
          size = None;
          id = Some (Folder_id.v "3f9a0c1b2d4e-40a");
        };
    ]
  in
  let body = Op.encode_entry ops in
  print_string body;
  p "round trip: %b\n" (Op.decode_entry body = Ok ops);
  List.iter
    (fun (what, b) ->
      p "%-34s %s\n" what
        (match Op.decode_entry b with
          | Ok l -> Printf.sprintf "%d ops" (List.length l)
          | Error e -> "CORRUPT (" ^ e ^ ")"))
    [
      ( "unknown op, unknown field",
        {|{"op":"chmod","key":"a"}|} ^ "\n"
        ^ {|{"op":"delete","key":"a","x":1}|} );
      ("blank lines, CRLF", "\r\n" ^ {|{"op":"delete","key":"a"}|} ^ "\r\n\r\n");
      ("missing size", {|{"op":"put","key":"a"}|});
      ("invalid path", {|{"op":"delete","key":"a/../b"}|});
      ("invalid folder id", {|{"op":"mkdir","key":"a","id":"Photos"}|});
      ( "uppercase base",
        {|{"op":"put","key":"a","size":1,"base":"8F3A0C1B2D4E5F60"}|} );
      ("not JSON", "hello");
    ];
  p "\n== WAL records (04 §2.8)\n";
  List.iter
    (fun (what, b) ->
      p "%-26s %s\n" what
        (match Wal.decode b with
          | Some r ->
              Printf.sprintf "%s, %d ops, attempts %d, priors %d, localFrom %d"
                (Wal.state_name r.state) (List.length r.ops) r.attempts
                (List.length r.priors) (List.length r.local_from)
          | None -> "unparseable"))
    [
      ( "spec example",
        {|{"state":"intent","attempts":2,"ops":[{"op":"rename","key":"b/new.txt","src":"a/old.txt","is_dir":false,"size":1234}],"priors":{"0":"3f2a9c1e0b7d4455"},"localFrom":{"0":"a/old (conflicted copy from laptop).txt"},"lastError":{"kind":"transient/link","detail":"connection reset"}}|}
      );
      ("unknown state", {|{"state":"weird","ops":[{"op":"delete","key":"a"}]}|});
      ( "op list",
        {|{"op":"delete","key":"a"}|} ^ "\n"
        ^ {|{"op":"put","key":"b","size":0}|} );
      ("unknown op", {|{"state":"prepared","ops":[{"op":"chmod","key":"a"}]}|});
      ( "priors naming no op",
        {|{"state":"prepared","ops":[{"op":"delete","key":"a"}],"priors":{"3":null}}|}
      );
      ("empty op list body", "\n\n");
      ("empty ops", {|{"state":"prepared","ops":[]}|});
      ("torn", {|{"state":"prep|});
    ];
  p "\n== staged manifests (04 §2.5)\n";
  let ex =
    {|{"v":2,"name":"report.txt","size":34,"mtime":1727600000.25,"chunkSize":8,"slots":[{}, {"u":"9f3c1a2b4d5e6f70"}, {"u":"9f3c1a2b4d5e6f70","o":8}, {"z":true}]}|}
  in
  List.iter
    (fun (what, b) ->
      p "%-22s %s\n" what
        (match Staged.decode b with
          | Some e -> (
              (match e.content with
                | Staged.Slots s ->
                    String.concat " "
                      (Array.to_list
                         (Array.map
                            (function
                              | Staged.Inherit -> "I"
                              | Zero -> "Z"
                              | Staged { body; off } ->
                                  Printf.sprintf "S(%s@%d)"
                                    (String.sub body 0 4) off)
                            s))
                | Whole b -> "whole " ^ b)
              ^
                match e.base with
                | Base_unknown -> ", base unknown"
                | Base_none -> ", base none"
                | Base h -> ", base " ^ h)
          | None -> "set aside"))
    [
      ("spec example", ex);
      ("no v, no chunkSize", {|{"name":"a","size":1,"mtime":0}|});
      ( "fewer slots",
        {|{"v":2,"name":"a","size":20,"mtime":0,"chunkSize":8,"slots":[{}],"base":null}|}
      );
      ("version 3", {|{"v":3,"name":"a","size":1,"mtime":0}|});
    ];
  let e = Option.get (Staged.decode ex) in
  p "round trip: %b\n" (Staged.decode (Staged.encode e) = Some e);
  p "\n== applied log (03 §2.7)\n";
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-applied-%d" (Unix.getpid ()))
  in
  Fs.rm_rf dir;
  let log = Applied.open_ dir in
  let k n = Entry_key.make ~ms:(Int64.of_int n) ~client:"c" in
  List.iter
    (fun n -> Applied.note log (k n) [Op.Delete (Printf.sprintf "f%d" n)])
    [1; 3; 2];
  Applied.note log (k 3) [];
  Fs.append_durable
    (Filename.concat dir
       (List.hd
          (List.filter
             (fun n -> String.ends_with ~suffix:".log" n)
             (Fs.readdir dir))))
    "\n0000000000009-c\t[{\"op\":\"del";
  let reopened = Applied.open_ dir in
  Applied.load reopened;
  let show = function
    | `Stale -> "stale"
    | `Page (pg : Applied.page) ->
        Printf.sprintf "[%s] more=%b"
          (String.concat " "
             (List.map (fun (k, _) -> Entry_key.to_string k) pg.entries))
          pg.more
  in
  p "from start: %s\n" (show (Applied.since reopened None 10));
  p "after 3, limit 1: %s\n" (show (Applied.since reopened (Some (k 3)) 1));
  p "after the head: %s\n" (show (Applied.since reopened (Some (k 2)) 10));
  p "unknown anchor: %s\n" (show (Applied.since reopened (Some (k 7)) 10));
  p "head: %s\n"
    (match Applied.head reopened with
      | Some k -> Entry_key.to_string k
      | None -> "none");
  Fs.rm_rf dir;
  p "\n== conflicted names (conflict-resolution §4.7)\n";
  List.iter
    (fun (leaf, is_dir, n) ->
      p "%-14s -> %s\n" leaf
        (Conflict.conflict_name ~client:"laptop" ~is_dir leaf n))
    [
      ("report.pdf", false, 1);
      ("archive.tar.gz", false, 2);
      ("Makefile", false, 1);
      (".bashrc", false, 1);
      ("v1.2", true, 1);
    ];
  p "\n== the Arrival table, exhaustively (conflict-resolution §4.3)\n";
  let occupants =
    Conflict.
      [
        Nothing;
        File;
        Staged_file;
        Renamed_file;
        Folder_same;
        Folder_ours;
        Folder_published;
        Folder_no_id;
      ]
  in
  let occ_name = function
    | Conflict.Nothing -> "none"
    | File -> "file"
    | Staged_file -> "staged_file"
    | Renamed_file -> "renamed_file"
    | Folder_same -> "folder(same)"
    | Folder_ours -> "folder(ours)"
    | Folder_published -> "folder(published)"
    | Folder_no_id -> "folder(no id)"
  in
  let row facts = p "  %-56s %s\n" facts in
  List.iter
    (fun sp ->
      List.iter
        (fun r ->
          List.iter
            (fun o ->
              List.iter
                (fun b ->
                  row
                    (Printf.sprintf "put S=%b removal=%b %s a2a=%b" sp r
                       (occ_name o) b)
                    (Conflict.describe
                       (Conflict.arrival
                          (Put_facts
                             {
                               store_present = sp;
                               removal = r;
                               occupant = o;
                               base_differs_from_own_view = b;
                             }))))
                (if o = File then [false; true] else [false]))
            occupants)
        [false; true])
    [false; true];
  List.iter
    (fun sp ->
      List.iter
        (fun r ->
          List.iter
            (fun o ->
              row
                (Printf.sprintf "delete S=%b removal=%b %s" sp r (occ_name o))
                (Conflict.describe
                   (Conflict.arrival
                      (Delete_facts
                         { store_present = sp; removal = r; occupant = o }))))
            occupants)
        [false; true])
    [false; true];
  List.iter
    (fun h ->
      List.iter
        (fun pl ->
          List.iter
            (fun r ->
              List.iter
                (fun o ->
                  row
                    (Printf.sprintf "mkdir held=%b %s removal=%b %s" h
                       (match pl with
                         | Conflict.In_trash -> "trashed"
                         | _ -> "placed")
                       r (occ_name o))
                    (Conflict.describe
                       (Conflict.arrival
                          (Mkdir_facts
                             { held = h; place = pl; removal = r; occupant = o }))))
                occupants)
            [false; true])
        [Conflict.In_trash; Place_unknown])
    [false; true];
  List.iter
    (fun rs ->
      List.iter
        (fun tg ->
          row
            (Printf.sprintf "rmdir restored=%b %s" rs
               (match tg with
                 | `By_id -> "by_id"
                 | `At_path -> "at_path"
                 | `Held_by_another -> "held_by_another"
                 | `Gone -> "gone"))
            (Conflict.describe
               (Conflict.arrival (Rmdir_facts { restored = rs; target = tg }))))
        [`By_id; `At_path; `Held_by_another; `Gone])
    [false; true];
  List.iter
    (fun o ->
      row
        (Printf.sprintf "rename dir, source at path, %s" (occ_name o))
        (Conflict.describe
           (Conflict.arrival
              (Rename_dir_facts
                 {
                   ours_owed = false;
                   place = Place_unknown;
                   source = `At_path;
                   already_there = false;
                   removal = false;
                   occupant = o;
                 }))))
    occupants;
  List.iter
    (fun (what, f) -> row what (Conflict.describe (Conflict.arrival f)))
    Conflict.
      [
        ( "rename dir, ours owed",
          Rename_dir_facts
            {
              ours_owed = true;
              place = Place_unknown;
              source = `At_path;
              already_there = false;
              removal = false;
              occupant = Nothing;
            } );
        ( "rename dir, trashed",
          Rename_dir_facts
            {
              ours_owed = false;
              place = In_trash;
              source = `At_path;
              already_there = false;
              removal = false;
              occupant = Nothing;
            } );
        ( "rename dir, source gone",
          Rename_dir_facts
            {
              ours_owed = false;
              place = Place_unknown;
              source = `Gone;
              already_there = false;
              removal = false;
              occupant = Nothing;
            } );
        ( "rename dir, already there",
          Rename_dir_facts
            {
              ours_owed = false;
              place = Place_unknown;
              source = `By_id;
              already_there = true;
              removal = false;
              occupant = Nothing;
            } );
        ( "rename dir, under our removal",
          Rename_dir_facts
            {
              ours_owed = false;
              place = Place_unknown;
              source = `By_id;
              already_there = false;
              removal = true;
              occupant = Nothing;
            } );
      ];
  List.iter
    (fun dp ->
      List.iter
        (fun r ->
          List.iter
            (fun o ->
              row
                (Printf.sprintf "rename file S(d)=%b removal=%b %s" dp r
                   (occ_name o))
                (Conflict.describe
                   (Conflict.arrival
                      (Rename_file_facts
                         { dst_present = dp; removal = r; occupant = o }))))
            occupants)
        [false; true])
    [false; true];
  p "\n== the Publish table (conflict-resolution §4.5)\n";
  let fact_name = function
    | Conflict.Base_current -> "base_current"
    | Store_moved_on -> "store_moved_on"
    | Here_again -> "here_again"
    | Store_gone -> "store_gone"
    | Store_as_expected -> "store_as_expected"
    | Store_changed -> "store_changed"
    | No_id -> "no_id"
    | Gone_here -> "gone_here"
    | Filed_elsewhere -> "filed_elsewhere"
    | Claimed -> "claimed"
    | Name_taken -> "name_taken"
    | Already_trashed -> "already_trashed"
    | Never_published -> "never_published"
    | Published -> "published"
    | Trashed -> "trashed"
    | Filed_here_already -> "filed_here_already"
    | Destination_taken -> "destination_taken"
    | Moved -> "moved"
    | Landed -> "landed"
    | Source_still_there -> "source_still_there"
    | Source_gone `Absent -> "source_gone(absent)"
    | Source_gone `Staged -> "source_gone(staged)"
    | Source_gone `Published -> "source_gone(published)"
  in
  let act = function
    | Conflict.P_ours_aside_file -> "ours-aside-file"
    | P_remove_from_store -> "remove-from-store"
    | P_put_marker -> "put-marker"
    | P_ours_aside -> "ours-aside"
    | P_retire_to_trash -> "retire-to-trash"
    | P_ours_aside_as_rename -> "ours-aside-as-rename"
    | P_move_marker -> "move-marker"
    | P_retarget_our_rename -> "retarget-our-rename"
    | P_queue_upload -> "queue-upload"
    | P_republish_here -> "republish-here"
  in
  let ending = function
    | Conflict.Publish -> "publish"
    | Nothing_owed -> "nothing_owed"
    | Superseded -> "superseded"
    | Again -> "again"
    | Retry -> "retry"
  in
  List.iter
    (fun (op, name, facts) ->
      List.iter
        (fun f ->
          let acts, e = Conflict.publish op f in
          p "  %-12s %-24s %-24s %s\n" name (fact_name f)
            (String.concat "," (List.map act acts))
            (ending e))
        facts)
    Conflict.
      [
        (`Put, "put", [Base_current; Store_moved_on]);
        ( `Delete,
          "delete",
          [Here_again; Store_gone; Store_as_expected; Store_changed] );
        ( `Mkdir,
          "mkdir",
          [No_id; Gone_here; Filed_elsewhere; Claimed; Name_taken] );
        (`Rmdir, "rmdir", [No_id; Already_trashed; Never_published; Published]);
        ( `Rename_dir,
          "rename dir",
          [
            Gone_here;
            Trashed;
            Filed_here_already;
            Never_published;
            Name_taken;
            Claimed;
          ] );
        ( `Rename_file,
          "rename file",
          [
            Destination_taken;
            Moved;
            Landed;
            Source_still_there;
            Source_gone `Absent;
            Source_gone `Staged;
            Source_gone `Published;
          ] );
      ]
