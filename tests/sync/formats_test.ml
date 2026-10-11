(* The persistent formats of 03 and 04: what is written, and what a reader
   accepts, refuses or sets aside. *)

open Tsync_core
open Tsync_sync
open Tsync_checkout

let p fmt = Printf.printf fmt

let scratch name =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-formats-%s-%d" name (Unix.getpid ()))
  in
  Fs.rm_rf dir;
  dir

let () =
  p "== feed keys (03 §2.2)\n";
  List.iter
    (fun s ->
      p "%-56S %s\n" s
        (match Feed_key.parse s with
          | Some k -> Feed_key.to_string k ^ " month " ^ Feed_key.month k
          | None -> "not a key"))
    [
      "1788134400000-3f9a0c1b2d4e5f60718293a4b5c6d7e8";
      "2026-08";
      "178813440000-abc";
      ".tsync-tmp-1-2.tmp";
    ];
  let minter =
    Feed_key.minter ~client:"c"
      ~seen:[Feed_key.make ~ms:9_999_999_999_999L ~client:"c"]
  in
  p "minted past a key from the future: %s\n"
    (Feed_key.to_string (Feed_key.mint minter));
  p "\n== feed ops (03 §2.9)\n";
  let folder = Folder_id.v "3f9a0c1b2d4e-40a" in
  let ops =
    [
      Op.Put { path = "photos/one.jpg"; size = 1024 };
      Op.Delete "photos/two.jpg";
      Op.Mkdir { path = "photos"; id = Some folder };
      Op.Rmdir { path = "photos"; id = Some folder };
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
          id = Some folder;
        };
    ]
  in
  List.iter (fun op -> print_endline (Op.to_string op)) ops;
  p "round trip: %b\n"
    (List.for_all (fun op -> Op.of_json (Op.to_json op) = Some op) ops);
  List.iter
    (fun (what, json) ->
      p "%-28s %s\n" what
        (match Op.of_json (Yojson.Safe.from_string json) with
          | Some _ -> "an op"
          | None -> "ignored"
          | exception Op.Bad e -> "bad: " ^ e))
    [
      ("unknown op", {|{"op":"chmod","key":"a"}|});
      ("unknown field", {|{"op":"delete","key":"a","mode":7}|});
      ("put without a size", {|{"op":"put","key":"a"}|});
      ("an absolute path", {|{"op":"delete","key":"/a"}|});
    ];
  p "\n== commands and log entries (03 §2.3–2.4)\n";
  let chunk content = Chunk_key.of_bigstring (Bigstring.of_string content) in
  let manifest name content =
    Manifest.make ~name ~size:(String.length content) ~mtime:1. ~chunk_size:8
      [chunk content]
  in
  let one = manifest "one.jpg" "first" and two = manifest "two.jpg" "second" in
  let at name = { Algebra.parent = folder; name } in
  let root_place name = { Algebra.parent = Folder_id.root; name } in
  let sub = Folder_id.v "3f9a0c1b2d4e-40b" in
  let batch : Log_entry.command list =
    [
      `File (at "one.jpg", None, Some (Known one));
      `File (at "two.jpg", Some (Known two), None);
      `Folder (sub, None, Some (root_place "Photos"));
      `Folder (folder, Some (root_place "Photos"), Some (root_place "Pics"));
    ]
  in
  let author = "3f9a0c1b2d4e5f60718293a4b5c6d7e8" in
  let body = Log_entry.encode { author; commands = batch } in
  let shown =
    (* The manifest bodies are binary: only their place in the object shows. *)
      match Yojson.Safe.from_string body with
      | `Assoc fields ->
          Yojson.Safe.to_string
            (`Assoc
               (List.map
                  (function
                    | "commands", `List l ->
                        ( "commands",
                          `List
                            (List.map
                               (function
                                 | `Assoc c ->
                                     `Assoc
                                       (List.map
                                          (function
                                            | "after", `String s
                                              when String.length s > 40 ->
                                                ("after", `String "<manifest>")
                                            | f -> f)
                                          c)
                                 | j -> j)
                               l) )
                    | f -> f)
                  fields))
      | j -> Yojson.Safe.to_string j
  in
  print_endline shown;
  (match Log_entry.decode body with
    | `Entry e ->
        p "decodes: author kept %b, %d commands, guards read as identities %b\n"
          (e.author = author) (List.length e.commands)
          (List.exists
             (function
               | `File (_, Some (Log_entry.Identity i), None) ->
                   i = Log_entry.identity_of two
               | _ -> false)
             e.commands)
    | _ -> p "DOES NOT DECODE\n");
  let refused f =
    match f () with
      | _ -> "accepted"
      | exception Fail.E e -> "refused: " ^ e.reason
  in
  p "an empty batch: %s\n"
    (refused (fun () -> Log_entry.encode { author; commands = [] }));
  p "two commands on one key: %s\n"
    (refused (fun () ->
         Log_entry.encode
           {
             author;
             commands =
               [
                 `File (at "a", None, Some (Known one));
                 `File (at "a", None, Some (Known two));
               ];
           }));
  p "a value after that is not a manifest: %s\n"
    (refused (fun () ->
         Log_entry.encode
           { author; commands = [`File (at "a", None, Some Unknown)] }));
  List.iter
    (fun (what, body) ->
      p "%-34s %s\n" what
        (match Log_entry.decode body with
          | `Entry e -> Printf.sprintf "%d commands" (List.length e.commands)
          | `Later_version v ->
              Printf.sprintf "version %d: cannot be followed" v
          | `Corrupt e -> "CORRUPT (expected " ^ e ^ ")"))
    [
      ( "unknown fields",
        {|{"v":1,"author":"a","x":1,"commands":[{"folder":"3f9a0c1b2d4e-40b","before":null,"after":null,"y":2}]}|}
      );
      ("a later version", {|{"v":2,"author":"a","commands":"something else"}|});
      ( "no author",
        {|{"v":1,"commands":[{"folder":"3f9a0c1b2d4e-40b","before":null,"after":null}]}|}
      );
      ( "a command without before",
        {|{"v":1,"author":"a","commands":[{"folder":"3f9a0c1b2d4e-40b","after":null}]}|}
      );
      ( "both file and folder",
        {|{"v":1,"author":"a","commands":[{"file":["3f9a0c1b2d4e-40a","x"],"folder":"3f9a0c1b2d4e-40b","before":null,"after":null}]}|}
      );
      ( "the root as a folder key",
        {|{"v":1,"author":"a","commands":[{"folder":".tsync-root","before":null,"after":null}]}|}
      );
      ( "an invalid folder id",
        {|{"v":1,"author":"a","commands":[{"folder":"../x","before":null,"after":null}]}|}
      );
      ( "an invalid leaf",
        {|{"v":1,"author":"a","commands":[{"file":["3f9a0c1b2d4e-40a","a/b"],"before":null,"after":null}]}|}
      );
      ( "a guard that is no identity",
        {|{"v":1,"author":"a","commands":[{"file":["3f9a0c1b2d4e-40a","x"],"before":"abc","after":null}]}|}
      );
      ( "an after that is no manifest",
        {|{"v":1,"author":"a","commands":[{"file":["3f9a0c1b2d4e-40a","x"],"before":null,"after":"aGVsbG8="}]}|}
      );
      ( "two commands on one key",
        {|{"v":1,"author":"a","commands":[{"folder":"3f9a0c1b2d4e-40b","before":null,"after":null},{"folder":"3f9a0c1b2d4e-40b","before":null,"after":null}]}|}
      );
      ("no commands", {|{"v":1,"author":"a","commands":[]}|});
      ("not JSON", "tsyncm03");
    ];
  let d = Domain_name.v "photos" in
  p "entry 1 234 567: %s\n" (Key.to_string (Key.log_entry d 1_234_567));
  p "takeover of entry 7, generation 2: %s\n"
    (Key.to_string (Key.takeover d 7 ~generation:2));
  p "void of entry 7: %s\n" (Key.to_string (Key.void d 7));
  p "the gate reads %d chunks from the entry\n"
    (match Log_entry.chunk_names (Bigstring.of_string body) with
      | Ok l -> List.length l
      | Error e -> failwith e);
  p "\n== sync state (03 §2.7–2.8)\n";
  let data_dir = scratch "state" in
  let state = Sync_state.open_ ~data_dir d in
  p "no position: %b\n" (Sync_state.position state = None);
  Sync_state.set_position state 1_234_567;
  p "position file: %S\n"
    (Fs.read_file
       (List.fold_left Filename.concat data_dir ["sync"; "photos"; "position"]));
  Sync_state.record_file state (at "one.jpg") (Some (Known one));
  Sync_state.record_file state (at "one.jpg") None;
  Sync_state.record_file state (at "new.jpg") None;
  Sync_state.record_folder state sub (Some (root_place "Photos"));
  Sync_state.record_file state (root_place "top.txt") None;
  let before_dir =
    List.fold_left Filename.concat data_dir ["sync"; "photos"; "before"]
  in
  List.iter
    (fun name ->
      p "  %s: %s\n"
        (if String.length name > 20 then String.sub name 0 20 ^ "…" else name)
        (Fs.read_file (Filename.concat before_dir name)))
    (List.sort compare (Fs.readdir before_dir));
  p "a second record of one key changes nothing: %b\n"
    (Sync_state.before_file state (at "one.jpg")
     = Some (Some (Identity (Log_entry.identity_of one)))
    || Sync_state.before_file state (at "one.jpg") = Some (Some (Known one)));
  p "pending: %d\n" (Sync_state.pending_count state);
  Sync_state.set_in_flight state { n = 8; body };
  let arrival : Sync_state.arrival =
    {
      head = 9;
      view = None;
      steps =
        [
          Move (at "a.txt", at "a (conflicted copy from laptop).txt");
          File (at "a.txt", Some (Manifest.rename one "a.txt"));
          File (at "b.txt", None);
          Folder (sub, Some (root_place "Pics"));
          Folder (folder, None);
        ];
      before =
        [
          (`File (at "a (conflicted copy from laptop).txt"), Before_file None);
          (`File (at "a.txt"), Drop);
          (`Folder sub, Before_folder (Some (root_place "Photos")));
        ];
    }
  in
  Sync_state.set_arrival state arrival;
  let reopened = Sync_state.open_ ~data_dir d in
  p
    "reopened: position %s, pending %d, in flight for entry %s, arrival kept %b\n"
    (match Sync_state.position reopened with
      | Some n -> string_of_int n
      | None -> "none")
    (Sync_state.pending_count reopened)
    (match Sync_state.in_flight reopened with
      | Some f when f.body = body -> string_of_int f.n
      | _ -> "none")
    (Sync_state.arrival reopened = Some arrival);
  p "a file of the root is still pending: %b\n"
    (Sync_state.before_file reopened (root_place "top.txt") = Some None);
  p "needs a state read: %b\n" (Sync_state.needs_state reopened);
  Fs.write_file_for_test
    (Filename.concat before_dir ("d-" ^ Folder_id.to_string sub))
    "{torn";
  Fs.write_file_for_test
    (List.fold_left Filename.concat data_dir ["sync"; "photos"; "arrival"])
    "not json";
  let damaged = Sync_state.open_ ~data_dir d in
  p "an unparseable arrival reads as none: %b\n"
    (Sync_state.arrival damaged = None);
  p
    "after two unparseable records: pending %d, needs a state read %b, set \
     aside %s\n"
    (Sync_state.pending_count damaged)
    (Sync_state.needs_state damaged)
    (String.concat " "
       (List.filter
          (fun n -> String.ends_with ~suffix:".bad" n)
          (List.sort compare
             (Fs.readdir before_dir
             @ Fs.readdir
                 (List.fold_left Filename.concat data_dir ["sync"; "photos"])))));
  Fs.rm_rf data_dir;
  p "\n== upload records and local intents (04 §2.8)\n";
  let upload =
    {
      Local_ops.file = at "report.txt";
      attempts = 2;
      last_error = Some ("transient/link", "connection reset");
    }
  in
  let encoded = Local_ops.upload_kind.encode upload in
  print_endline encoded;
  p "round trip: %b; key %s\n"
    (Local_ops.upload_kind.decode encoded = Some upload)
    (Option.value ~default:"none" (Local_ops.upload_kind.key upload));
  p "no attempts, no error: %b\n"
    (Local_ops.upload_kind.decode {|{"file":["3f9a0c1b2d4e-40a","report.txt"]}|}
    = Some { upload with attempts = 0; last_error = None });
  p "a folder key: %s\n"
    (match Local_ops.upload_kind.decode {|{"folder":"3f9a0c1b2d4e-40a"}|} with
      | Some _ -> "accepted"
      | None -> "set aside");
  let intent =
    Local_ops.encode_intent
      (Op.Rename
         {
           dst = "b/new.txt";
           src = "a/old.txt";
           is_dir = false;
           size = None;
           id = None;
         })
      ["6c1e0b9a2f4d47e8a3b5c7d9e1f20384"]
  in
  print_endline intent;
  p "round trip: %b\n"
    (match Local_ops.decode_intent intent with
      | Some (Op.Rename { dst = "b/new.txt"; _ }, [_]) -> true
      | _ -> false);
  p "an op this reader does not know: %s\n"
    (match Local_ops.decode_intent {|{"op":{"op":"chmod","key":"a"}}|} with
      | Some _ -> "run"
      | None -> "set aside");
  p "\n== staged manifests (04 §2.5)\n";
  let ex =
    {|{"v":2,"name":"report.txt","size":34,"mtime":1727600000.25,"chunkSize":8,"slots":[{}, {"u":"9f3c1a2b4d5e6f70"}, {"u":"9f3c1a2b4d5e6f70","o":8}, {"z":true}]}|}
  in
  let uploaded = Base64.encode_string one.body in
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
                | Whole { body; h1 } ->
                    "whole " ^ body
                    ^ Option.fold ~none:"" ~some:(fun h -> " h1 " ^ h) h1)
              ^
                match e.state with
                | Owed -> ", Owed"
                | Uploaded _ -> ", Uploaded")
          | None -> "set aside"))
    [
      ("spec example", ex);
      ("no v, no chunkSize", {|{"name":"a","size":1,"mtime":0}|});
      ( "fewer slots",
        {|{"v":2,"name":"a","size":20,"mtime":0,"chunkSize":8,"slots":[{}]}|} );
      ( "uploaded",
        Printf.sprintf
          {|{"v":2,"name":"a","size":5,"mtime":0,"chunkSize":8,"slots":[{}],"uploaded":%S}|}
          uploaded );
      ( "uploaded, not a manifest",
        {|{"v":2,"name":"a","size":5,"mtime":0,"chunkSize":8,"slots":[{}],"uploaded":"aGVsbG8="}|}
      );
      ("version 3", {|{"v":3,"name":"a","size":1,"mtime":0}|});
    ];
  let e = Option.get (Staged.decode ex) in
  p "round trip: %b\n" (Staged.decode (Staged.encode e) = Some e);
  p "\n== applied log (03 §2.9)\n";
  let dir = scratch "applied" in
  let log = Applied.open_ dir in
  let k n = Feed_key.make ~ms:(Int64.of_int n) ~client:"c" in
  let fid = "6c1e0b9a2f4d47e8a3b5c7d9e1f20384" in
  List.iter
    (fun n ->
      Applied.note
        ~fids:(if n = 1 then [(0, fid)] else [])
        log (k n)
        [Op.Delete (Printf.sprintf "f%d" n)])
    [1; 2; 3];
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
             (List.map
                (fun (k, (ops : Applied.op list)) ->
                  Feed_key.to_string k
                  ^ String.concat ""
                      (List.map
                         (fun (o : Applied.op) ->
                           match o.fid with
                             | Some id -> "(fid " ^ String.sub id 0 4 ^ ")"
                             | None -> "")
                         ops))
                pg.entries))
          pg.more
  in
  p "from start: %s\n" (show (Applied.since reopened None 10));
  p "after 1, limit 1: %s\n" (show (Applied.since reopened (Some (k 1)) 1));
  p "after the head: %s\n" (show (Applied.since reopened (Some (k 3)) 10));
  p "unknown anchor: %s\n" (show (Applied.since reopened (Some (k 7)) 10));
  p "head, past the torn line: %s\n"
    (match Applied.head reopened with
      | Some k -> Feed_key.to_string k
      | None -> "none");
  Fs.rm_rf dir;
  p "\n== conflicted names (conflict-resolution §5)\n";
  List.iter
    (fun (leaf, is_dir, n) ->
      p "%-14s -> %s\n" leaf (Conflict.name ~client:"laptop" ~is_dir leaf n))
    [
      ("report.pdf", false, 1);
      ("archive.tar.gz", false, 2);
      ("Makefile", false, 1);
      (".bashrc", false, 1);
      ("v1.2", true, 1);
    ]
