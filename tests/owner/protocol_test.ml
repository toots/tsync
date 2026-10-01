(* Every request and reply of the hand-written codec reads back as written. *)
open Tsync_owner.Protocol

type case = Case : 'a request * 'a -> case

let row : row =
  {
    ref_ = "f:9f3a/big.txt";
    parent_ref = "d:9f3a";
    name = "big.txt";
    kind = `File;
    size = 24;
    mtime = 1400000000.;
    etag = "1294bbe85c2f380b";
    is_uploaded = true;
    content_id = Some "1294bbe85c2f380b";
    symlink_target = None;
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
    Case
      (Ensure_cached { item = Ref "f:9f3a/big.txt"; dest = "/tmp/x" }, "/tmp/x");
    Case
      ( Fetch_range
          { item = Rel "big.txt"; dest = "/tmp/y"; offset = 4; length = 8 },
        { local_path = "/tmp/y"; offset = 4; length = 8 } );
    Case
      (Download_progress (Rel "big.txt"), Active { downloaded = 3; total = 9 });
    Case (Create { at; exclusive = true }, row);
    Case
      ( Write { at; staging = "/tmp/s"; base = Some "abcd"; exclusive = false },
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
      ( Share { rel = "docs/a.txt"; expires = Some 3600.; token = None },
        { url = "https://s.example/d/0123"; expires = 1790000000. } );
    Case
      ( Share { rel = ""; expires = None; token = Some (String.make 32 'a') },
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
