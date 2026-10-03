(* Every request and reply of the hand-written codec reads back as written. *)
open Tsync_owner.Protocol

type case = Case : 'a request * 'a -> case

let row : row =
  {
    ref_ = "i:6c1e0b9a2f4d47e8a3b5c7d9e1f20384";
    parent_ref = "d:9f3a";
    name = "big.txt";
    kind = `File;
    size = 24;
    mtime = 1400000000.;
    etag = "1294bbe85c2f380b";
    is_uploaded = true;
    content_id = Some "1294bbe85c2f380b";
    symlink_target = None;
    read_only = false;
    availability = Some (Pinned 1500000000.);
  }

let dir =
  {
    row with
    ref_ = "d:9f3a";
    kind = `Dir;
    availability = None;
    content_id = None;
  }

let at = { parent_ref = "d:9f3a"; name = "big.txt" }

let cases =
  [
    Case (Ping, ());
    Case (Stat (Ref "f:9f3a/big.txt"), row);
    Case (Stat (Rel "docs/big.txt"), row);
    Case
      ( List_dir { dir = Ref "d:9f3a"; after = Some "a"; limit = Some 2 },
        { items = [row; dir]; next = Some "big.txt"; unnamed = 1 } );
    Case (Cursor, "1756600000000|0001756600000-abc");
    Case (List_all { after = None; limit = Some 2 }, Walk_stale);
    Case
      ( List_all { after = Some "1700000000000:42"; limit = None },
        Listed
          { items = [row; dir]; next = Some "1700000000000:99"; unnamed = 0 } );
    Case (Changes_since { anchor = "1|"; limit = None }, Stale);
    Case
      ( Changes_since { anchor = "1|"; limit = Some 10 },
        Changes
          {
            cursor = "1|0001756600000-abc";
            more = true;
            unnamed = 2;
            ops =
              [
                Put_op
                  {
                    ref_ = row.ref_;
                    parent_ref = "d:9f3a";
                    name = "big.txt";
                    item = Some row;
                  };
                Delete_op
                  { ref_ = row.ref_; parent_ref = "d:9f3a"; name = "big.txt" };
                Mkdir_op
                  {
                    ref_ = "d:9f3a";
                    parent_ref = "root";
                    name = "d";
                    item = None;
                  };
                Rmdir_op
                  {
                    id = "9f3a";
                    ref_ = "d:9f3a";
                    parent_ref = "root";
                    name = "d";
                  };
                Rename_op
                  {
                    is_dir = false;
                    id = None;
                    src_ref = row.ref_;
                    src_parent_ref = "root";
                    ref_ = row.ref_;
                    parent_ref = "d:9f3a";
                    name = "big.txt";
                    item = Some row;
                  };
              ];
          } );
    Case
      ( Ensure_cached { item = Ref "f:9f3a/big.txt"; dest = "/tmp/x" },
        { local_path = "/tmp/x"; item = row } );
    Case (Stat (Child at), { row with read_only = true });
    Case
      ( Fetch_range
          { item = Rel "big.txt"; dest = "/tmp/y"; offset = 4; length = 8 },
        { local_path = "/tmp/y"; offset = 4; length = 8; item = row } );
    Case
      (Download_progress (Rel "big.txt"), Active { downloaded = 3; total = 9 });
    Case (Create { at; exclusive = true }, row);
    Case
      ( Write
          {
            at = Child at;
            staging = "/tmp/s";
            base = Some "abcd";
            exclusive = false;
          },
        { size = 24; mtime = 1400000000.; item = row } );
    Case
      ( Write
          {
            at = Ref row.ref_;
            staging = "/tmp/s";
            base = None;
            exclusive = false;
          },
        { size = 24; mtime = 1400000000.; item = row } );
    Case (Mkdir { at; exclusive = false }, dir);
    Case
      ( Symlink { at; link_target = "../x"; exclusive = true },
        {
          row with
          kind = `Symlink;
          symlink_target = Some "../x";
          availability = None;
          content_id = None;
        } );
    Case (Rename { src = "f:1/a"; at; noreplace = true }, row);
    Case (Delete (Ref "f:9f3a/big.txt"), ());
    Case (Rmdir (Ref "d:9f3a"), ());
    Case (Evict (Ref "root"), { succeeded = 3; failed = 1 });
    Case
      ( Restore { item = Ref "root"; keep = Some 60. },
        { succeeded = 2; failed = 0 } );
    Case (Full_resync, ());
    Case (Sync { full = true }, Full { manifests = 12; failed = 1 });
    Case (Sync { full = false }, Incremental 5);
    Case (Trash_restore "Holidays/2019", Restored 42);
    Case (Trash_restore "nowhere", Not_in_trash);
    Case (Trash_restore "Holidays/2019", Name_taken);
    Case
      ( Job
          {
            job =
              Gc
                {
                  apply = true;
                  verify = false;
                  abort = false;
                  budget = Some 60.;
                };
            narrate = true;
          },
        0 );
    Case
      ( Job
          {
            job = Purge { apply = false; path = "Holidays/2019" };
            narrate = false;
          },
        1 );
    Case (Job { job = Gc_copies Probe; narrate = false }, 0);
    Case
      ( Share { item = Rel "docs/a.txt"; expires = Some 3600.; token = None },
        { url = "https://s.example/d/0123"; expires = 1790000000. } );
    Case
      ( Share
          {
            item = Ref "i:6c1e0b9a2f4d47e8a3b5c7d9e1f20384";
            expires = None;
            token = Some (String.make 32 'a');
          },
        { url = "https://s.example/d/aaaa"; expires = 1790000000. } );
    Case (Share_revoke "https://s.example/d/0123", true);
    Case (Share_clear_cache, (3, 4096));
    Case (Cancel 3, true);
    Case (Cancel 4, false);
    Case (Retry, 4);
    Case (Poll, ());
    Case (Notify_reset, 2);
    Case
      ( Status,
        {
          domain = "docs";
          read_only = false;
          paused = true;
          pending_uploads = 3;
          pending_downloads = 1;
          uploading =
            [
              {
                name = "a.mkv";
                rel = "v/a.mkv";
                bytes = 0;
                size = 9;
                seconds = 1.;
                rate = 0.;
              };
            ];
          downloading =
            [
              {
                name = "b.mkv";
                rel = "b.mkv";
                bytes = 4;
                size = 8;
                seconds = 2.;
                rate = 2.;
              };
            ];
          pending_bytes = 9;
          subscribers = 2;
          unnamed = 1;
          traffic =
            { up_bytes = 10; up_rate = 1.5; down_bytes = 4; down_rate = 2. };
          mount = Some "/m";
        } );
    Case (Pause false, false);
    Case (Stop, ());
  ]

let () =
  List.iter
    (fun (Case (req, reply)) ->
      let wire = encode ~domain:"docs" req in
      let again =
        match decode wire with Request r -> encode ~domain:"docs" r
      in
      let back =
        decode_reply req
          (Yojson.Safe.from_string
             (Yojson.Safe.to_string (encode_reply req reply)))
      in
      Printf.printf "%-17s request %s, reply %s\n" (action req)
        (if Yojson.Safe.equal wire again then "reads back"
         else "CHANGED " ^ Yojson.Safe.to_string again)
        (if back = reply then "reads back" else "CHANGED"))
    cases;
  Printf.printf "a failure reply raises its kind: %s\n"
    (match
       decode_reply Ping
         (`Assoc
            [
              ("ok", `Bool false);
              ("code", `String "paused");
              ("error", `String "x");
            ])
     with
      | () -> "no"
      | exception Tsync_core.Fail.E f -> Tsync_core.Fail.kind_name f.kind);
  Printf.printf "an unknown action is refused: %s\n"
    (match decode (`Assoc [("action", `String "fly")]) with
      | _ -> "no"
      | exception Tsync_core.Fail.E f -> f.reason)
