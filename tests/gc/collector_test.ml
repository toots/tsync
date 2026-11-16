(* The collector against a local main and a local replica (spec
   algorithms/gc.md §10): what is kept, reclaimed and restored, on each store. *)

open Tsync_core
open Tsync_store
open Tsync_gc

let p fmt = Printf.printf fmt
let d = Domain_name.v "d"

let manifest cks =
  let cs = Chunking.chunk_size_min in
  (Manifest.make ~name:"f"
     ~size:(List.length cks * cs)
     ~times:{ Tsync_core.Fs.mtime = 0; created = 0 }
     ~chunk_size:cs cks)
    .body

let knowledge =
  {
    Composite.is_index = (fun k -> Key.leaf k = ".tsync-index");
    is_log = (fun k -> Key.under (Key.log d) k);
  }

let rec files dir =
  match Fs.readdir_opt dir with
    | None -> []
    | Some names ->
        List.concat_map
          (fun n ->
            let p = Filename.concat dir n in
            if Fs.is_dir p then files p else [p])
          names
        |> List.sort String.compare

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-gc-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  let main_root = Filename.concat root "main" in
  let main = Local.create ~name:"main" main_root
  and replica = Local.create ~name:"replica" (Filename.concat root "replica") in
  let names = Hashtbl.create 16 in
  let chunk name =
    let c = Chunk_key.of_body name in
    Hashtbl.replace names (Chunk_key.to_string c) name;
    c
  in
  let on_disk store_root key =
    Fs.exists (Filename.concat store_root (Key.to_string key))
  in
  Rt.run_sync (fun () ->
      let c =
        Composite.create ~domain:d
          ~data_dir:(Filename.concat root "data")
          ~owner:true ~poke:ignore ~knowledge
          [
            { name = "main"; role = Main; store = main };
            { name = "replica"; role = Replica; store = replica };
          ]
      in
      Composite.start c;
      let s = Composite.store c in
      (* Both stores directly: a best-effort forward would make the replica's
         holdings a matter of timing. *)
      let put_chunks l =
        List.iter
          (fun n ->
            let key = Key.chunk d (chunk n) and body = Bigstring.of_string n in
            main.put key body;
            replica.put key body)
          l
      in
      let publish key l =
        s.put key (Bigstring.of_string (manifest (List.map chunk l)))
      in
      let trashed = Folder_id.v "0123456789ab-1" in
      let slot id leaf = Key.child d id leaf in
      put_chunks ["live1"; "live2"; "live3"; "ver"; "trashed"; "junk1"; "junk2"];
      publish (slot Folder_id.root "a") ["live1"; "live2"];
      publish (slot Folder_id.root "b") ["live3"; "live1"];
      publish (Key.version d ~group:"0123456789ab-2/h" ~ns:1L) ["ver"];
      publish (slot trashed "t") ["trashed"];
      s.put
        (Key.child d Folder_id.root "folder")
        (Bigstring.of_string
           {|{"dir":true,"name":"folder","id":"0123456789ab-1"}|});
      Composite.settle ~timeout:10. c;
      let generation () =
        Option.fold ~none:"unreadable" ~some:string_of_int
          (Gc_generation.read main d)
      in
      let rec settled n =
        match Gc_generation.read main d with
          | Some g when g mod 2 = 0 -> true
          | _ when n = 0 -> false
          | _ ->
              Rt.sleep 0.1;
              settled (n - 1)
      in
      let state () =
        let sorted =
          Hashtbl.fold (fun k n acc -> (n, k) :: acc) names []
          |> List.sort compare
        in
        List.iter
          (fun (n, k) ->
            let c = Option.get (Chunk_key.of_string k) in
            p "  %-8s main S %b F %b, replica %b\n" n
              (on_disk main_root (Key.chunk d c))
              (on_disk main_root (Key.chunk_from d c))
              (Contract.get replica (Key.chunk d c) <> None))
          sorted;
        p "  run open %b, outgoing space %b, G %s\n"
          (on_disk main_root (Key.gc_run d))
          (Fs.exists (Filename.concat main_root "tsync/d/chunks.from"))
          (generation ())
      in
      let outcome = function
        | Collector.Completed -> "completed"
        | Suspended { phase; cursor } ->
            Printf.sprintf "suspended in %s at %S"
              (Gc_record.phase_name phase)
              cursor
        | Halted r -> "halted: " ^ r
      in
      (* Unless [held], a busy lock is the test's own settles, which a slow
         runner can catch holding it a moment, so it is waited out. *)
      let run ?budget ?expiring ?verify ?keep ?cancelled ?(held = false) () =
        let rec attempt tries =
          match Collector.run ?budget ?expiring ?verify ?keep ?cancelled c with
            | Error Busy when (not held) && tries > 0 ->
                Rt.sleep 0.1;
                attempt (tries - 1)
            | result -> result
        in
        match attempt 100 with
          | Ok [st] ->
              p "run: %s; promoted %d, reclaimed %d (%d bytes)%s%s\n"
                (outcome st.outcome) st.chunks_promoted st.chunks_reclaimed
                st.bytes_reclaimed
                (if st.versions_expired > 0 then
                   Printf.sprintf ", expired %d versions" st.versions_expired
                 else "")
                (if st.chunks_verified > 0 then
                   Printf.sprintf ", verified %d, corrupt %d" st.chunks_verified
                     st.chunks_corrupt
                 else "");
              st.outcome
          | Ok _ -> failwith "one main expected"
          | Error Busy ->
              p "run: busy\n";
              Halted "busy"
          | Error (Unsupported r) ->
              p "run: unsupported: %s\n" r;
              Halted r
          | Error (Refused r) ->
              p "run: refused: %s\n" r;
              Halted r
      in
      let show_status () =
        List.iter
          (fun (s : Collector.status) ->
            p "  status: %s, generation %s, %d owed\n"
              (match s.record with
                | Absent -> "no run"
                | Unreadable -> "unreadable run"
                | Record r ->
                    Printf.sprintf "%s after %S"
                      (Gc_record.phase_name r.phase)
                      r.cursor)
              (Option.fold ~none:"unreadable" ~some:string_of_int s.generation)
              s.owed)
          (Collector.status c)
      in
      p "== dry run (§5.9)\n";
      let before = files main_root in
      (match Collector.dry_run ~verify:true c with
        | Ok [Ok sv] ->
            p
              "referenced %d, reclaimable %d (%d bytes), missing %d, corrupt \
               %d, per copy %s\n"
              sv.chunks_referenced sv.chunks_reclaimable sv.bytes_reclaimable
              (List.length sv.chunks_missing)
              sv.chunks_corrupt
              (String.concat ","
                 (List.map
                    (fun (n, k) -> Printf.sprintf "%s %d" n k)
                    sv.per_copy))
        | _ -> p "dry run failed\n");
      p "dry run changed nothing on the main: %b\n" (files main_root = before);
      (match
         Collector.dry_run
           ~expiring:[Key.version d ~group:"0123456789ab-2/h" ~ns:1L]
           c
       with
        | Ok [(Ok { expiry = Some e; _ } as sv)] ->
            let sv = Result.get_ok sv in
            p
              "with the version expiring: %d versions (%d bytes), freed %d (%d \
               bytes), reclaimable %d, referenced %d, missing %d, per copy %s\n"
              e.versions e.version_bytes e.chunks_freed e.bytes_freed
              sv.chunks_reclaimable sv.chunks_referenced
              (List.length sv.chunks_missing)
              (String.concat ","
                 (List.map
                    (fun (n, k) -> Printf.sprintf "%s %d" n k)
                    sv.per_copy))
        | _ -> p "dry run with an expiry failed\n");
      p "still nothing changed: %b\n" (files main_root = before);
      p "a cancelled dry run: %s\n"
        (match Collector.dry_run ~cancelled:(Fun.const true) c with
          | Ok [Error reason] -> reason
          | _ -> "not stopped");
      p "\n== a collection (§5.5)\n";
      ignore (run ());
      Composite.settle ~timeout:10. c;
      p "generation settled: %b\n" (settled 100);
      state ();
      show_status ();
      p "\n== a second run right after deletes nothing\n";
      ignore (run ());
      p "\n== one unit per session, a publication landing mid-run\n";
      put_chunks ["junk3"; "late"; "live4"];
      publish (slot trashed "c") ["live4"];
      let rec steps i =
        let o = run ~budget:0. () in
        if i = 1 then (
          p "  publishing a manifest naming late, now outgoing\n";
          publish (slot Folder_id.root "late") ["late"];
          p "  reading junk3 during the run: %b\n"
            (Contract.get s (Key.chunk d (chunk "junk3")) <> None);
          show_status ());
        match o with
          | Collector.Suspended _ when i < 20 -> steps (i + 1)
          | _ -> ()
      in
      steps 0;
      Composite.settle ~timeout:10. c;
      p "generation settled: %b\n" (settled 100);
      state ();
      p "\n== abort puts back everything still outgoing\n";
      put_chunks ["junk5"];
      p "  a run cancelled at once stops like a spent budget\n";
      ignore (run ~cancelled:(Fun.const true) ());
      p "junk5 outgoing: %b\n"
        (on_disk main_root (Key.chunk_from d (chunk "junk5")));
      ignore (run ~keep:true ());
      p "junk5 back in S: %b\n"
        (on_disk main_root (Key.chunk d (chunk "junk5")));
      state ();
      p "\n== verify keeps and marks a chunk that does not hash to its key\n";
      Fs.write_file_for_test
        (Filename.concat main_root
           (Key.to_string (Key.chunk d (chunk "live2"))))
        "scrambled";
      ignore (run ~verify:true ());
      p "live2 kept: %b, marked: %b\n"
        (on_disk main_root (Key.chunk d (chunk "live2")))
        (on_disk main_root (Key.marker d (chunk "live2")));
      Composite.settle ~timeout:10. c;
      ignore (settled 100);
      p "\n== verify, resumed, checks a chunk promoted before the kill\n";
      put_chunks ["rot"];
      publish (slot trashed "rot") ["rot"];
      ignore (run ~budget:0. ());
      Fs.write_file_for_test
        (Filename.concat main_root
           (Key.to_string (Key.chunk_from d (chunk "rot"))))
        "scrambled";
      p "promoted, as by a session killed before verifying: %b\n"
        (Chunk_spaces.promote
           (Option.get (Chunk_spaces.of_store main))
           d (chunk "rot"));
      ignore (run ~verify:true ());
      p "rot marked: %b\n" (on_disk main_root (Key.marker d (chunk "rot")));
      Composite.settle ~timeout:10. c;
      ignore (settled 100);
      p "\n== a body that is not a manifest halts, leaving the run open\n";
      Fs.write_file_for_test
        (Filename.concat main_root
           (Key.to_string (slot Folder_id.root "garbage")))
        "garbage";
      ignore (run ());
      p "run open: %b, live1 outgoing and readable: %b %b\n"
        (on_disk main_root (Key.gc_run d))
        (on_disk main_root (Key.chunk_from d (chunk "live1")))
        (Contract.get s (Key.chunk d (chunk "live1")) <> None);
      Unix.unlink
        (Filename.concat main_root
           (Key.to_string (slot Folder_id.root "garbage")));
      ignore (run ());
      Composite.settle ~timeout:10. c;
      p "generation settled: %b\n" (settled 100);
      state ();
      p "\n== a manifest with one malformed key halts, keeping its chunks\n";
      put_chunks ["solo1"; "solo2"];
      let malformed =
        let body = manifest [chunk "solo1"; chunk "solo2"] in
        let key = Chunk_key.to_string (chunk "solo2") in
        let at =
          let rec find i =
            if String.sub body i (String.length key) = key then i
            else find (i + 1)
          in
          find 0
        in
        String.mapi (fun i ch -> if i = at then 'Z' else ch) body
      in
      let malformed_path =
        Filename.concat main_root
          (Key.to_string (slot Folder_id.root "malformed"))
      in
      Fs.write_file_for_test malformed_path malformed;
      ignore (run ());
      p "solo1 and solo2 kept: %b %b\n"
        (Contract.get s (Key.chunk d (chunk "solo1")) <> None)
        (Contract.get s (Key.chunk d (chunk "solo2")) <> None);
      Unix.unlink malformed_path;
      ignore (run ());
      Composite.settle ~timeout:10. c;
      ignore (settled 100);
      p "\n== a settle leaves G odd while a run is suspended in closing\n";
      put_chunks ["junk6"; "junk7"];
      let rec to_closing i =
        match run ~budget:0. () with
          | Collector.Suspended { phase = Closing; _ } -> true
          | Suspended _ when i < 20 -> to_closing (i + 1)
          | _ -> false
      in
      p "suspended in closing: %b\n" (to_closing 0);
      Composite.settle ~timeout:10. c;
      p "G odd after a settle: %b\n"
        (match Gc_generation.read main d with
          | Some g -> g mod 2 = 1
          | None -> false);
      let rec finish i =
        match run ~budget:0. () with
          | Collector.Suspended _ when i < 20 -> finish (i + 1)
          | _ -> ()
      in
      finish 0;
      Composite.settle ~timeout:10. c;
      p "generation settled: %b\n" (settled 100);
      p "\n== expiry within the run (§5.5)\n";
      put_chunks ["exp1"; "exp2"; "shared"; "rev"];
      let version folder ns l =
        let key = Key.version d ~group:(folder ^ "/h") ~ns in
        publish key l;
        key
      in
      let va = version "0123456789ab-3" 10L ["exp1"; "shared"]
      and vb = version "0123456789ab-4" 11L ["exp2"]
      and vr = version "0123456789ab-5" 12L ["rev"]
      and kept = Key.version d ~group:"0123456789ab-2/h" ~ns:1L in
      publish (slot Folder_id.root "sh") ["shared"];
      Composite.settle ~timeout:10. c;
      let expiring = [va; vb; vr] in
      let present k = on_disk main_root k in
      let x_saved () = on_disk main_root (Key.gc_expiry d) in
      let freed, unused =
        match Collector.dry_run ~expiring c with
          | Ok [Ok { expiry = Some e; chunks_reclaimable; _ }] ->
              p "dry run: %d versions, freed %d, already unused %d\n" e.versions
                e.chunks_freed chunks_reclaimable;
              (e.chunks_freed, chunks_reclaimable)
          | _ ->
              p "dry run failed\n";
              (0, 0)
      in
      let reclaimed = ref 0 in
      let step ?expiring () =
        match Collector.run ~budget:0. ?expiring c with
          | Ok [st] ->
              reclaimed := !reclaimed + st.chunks_reclaimed;
              st.outcome
          | Error (Refused r) ->
              p "  refused: %s\n" r;
              Halted r
          | _ -> Halted "failed"
      in
      ignore (step ~expiring ());
      p "after one unit: X saved %b, versions present %b %b %b\n" (x_saved ())
        (present va) (present vb) (present vr);
      p "  reverting the version of rev before its group is marked\n";
      publish (slot Folder_id.root "rev") ["rev"];
      p "  a different expiry against the open run:\n";
      ignore (step ~expiring:[va; kept] ());
      p "  the same command again, some versions perhaps gone:\n";
      ignore (step ~expiring:(List.filter present expiring) ());
      let rec drain i =
        match step () with
          | Collector.Suspended _ when i < 40 -> drain (i + 1)
          | o -> o
      in
      p "resumed without arguments: %s\n" (outcome (drain 0));
      p "versions gone %b %b %b, kept one present %b, X gone %b\n"
        (not (present va))
        (not (present vb))
        (not (present vr))
        (present kept)
        (not (x_saved ()));
      p "exp1 exp2 gone %b %b; shared rev kept %b %b\n"
        (not (on_disk main_root (Key.chunk d (chunk "exp1"))))
        (not (on_disk main_root (Key.chunk d (chunk "exp2"))))
        (on_disk main_root (Key.chunk d (chunk "shared")))
        (on_disk main_root (Key.chunk d (chunk "rev")));
      p
        "reclaimed %d = dry run freed %d + already unused %d less rev, \
         reverted: %b\n"
        !reclaimed freed unused
        (!reclaimed = freed + unused - 1);
      Composite.settle ~timeout:10. c;
      ignore (settled 100);
      p "\n== abort after an expiry: chunks back, versions stay deleted\n";
      put_chunks ["exp3"];
      let vc = version "0123456789ab-6" 13L ["exp3"] in
      Composite.settle ~timeout:10. c;
      let rec until_gone i =
        ignore (step ~expiring:(if i = 0 then [vc] else []) ());
        if present vc && i < 40 then until_gone (i + 1)
      in
      until_gone 0;
      p "  a damaged expiry set beside the open run\n";
      Fs.write_file_for_test
        (Filename.concat main_root (Key.to_string (Key.gc_expiry d)))
        "/torn\nnot a version\n";
      ignore (run ~keep:true ());
      p "version gone %b, exp3 back in S %b, X gone %b\n"
        (not (present vc))
        (on_disk main_root (Key.chunk d (chunk "exp3")))
        (not (x_saved ()));
      p "\n== an expiring version the collected main does not hold\n";
      let far = Key.version d ~group:"0123456789ab-7/h" ~ns:14L in
      replica.put far (Bigstring.of_string (manifest [chunk "shared"]));
      let expired = ref 0 in
      let rec drain_far i =
        match
          Collector.run ~budget:0.
            ?expiring:(if i = 0 then Some [far] else None)
            c
        with
          | Ok [st] -> (
              expired := !expired + st.versions_expired;
              match st.outcome with
                | Suspended _ when i < 40 -> drain_far (i + 1)
                | o -> o)
          | Ok l -> Halted (Printf.sprintf "%d mains answered" (List.length l))
          | Error Busy -> Halted "busy"
          | Error (Unsupported r) -> Halted ("unsupported: " ^ r)
          | Error (Refused r) -> Halted ("refused: " ^ r)
      in
      let o = drain_far 0 in
      p "run: %s, %d versions expired\n" (outcome o) !expired;
      Composite.settle ~timeout:10. c;
      ignore (settled 100);
      p "deleted on the replica: %b\n" (Contract.get replica far = None);
      p "\n== a run opened without an expiry refuses one\n";
      ignore (step ());
      ignore (step ~expiring:[kept] ());
      p "kept still present: %b\n" (present kept);
      ignore (run ~keep:true ());
      Composite.settle ~timeout:10. c;
      ignore (settled 100);
      p "\n== exclusion\n";
      let to_holder, holder_in = Unix.pipe ~cloexec:true ()
      and holder_out, from_holder = Unix.pipe ~cloexec:true () in
      (* A settle the previous jobs spawned may hold the run lock a moment. *)
      let pid =
        Unix.create_process "./lock_holder.exe"
          [| "./lock_holder.exe"; main_root; "d"; "wait" |]
          to_holder from_holder Unix.stderr
      in
      Unix.close to_holder;
      Unix.close from_holder;
      p "another process: %s\n"
        (input_line (Unix.in_channel_of_descr holder_out));
      ignore (run ~held:true ());
      Unix.close holder_in;
      ignore (Unix.waitpid [] pid);
      p "after it exits: ";
      ignore (run ());
      let () =
        match
          Chunk_spaces.with_run_lock (Chunk_spaces.create main_root) d
            (fun () -> run ~held:true ())
        with
          | Ok _ -> ()
          | Error `Busy -> p "the test could not take the lock\n"
      in
      let spaces = Chunk_spaces.create main_root in
      ignore
        (Chunk_spaces.with_run_lock spaces d (fun () ->
             Chunk_spaces.with_publish_lock spaces d ~exclusive:false ignore;
             let to_holder, holder_in = Unix.pipe ~cloexec:true ()
             and holder_out, from_holder = Unix.pipe ~cloexec:true () in
             let pid =
               Unix.create_process "./lock_holder.exe"
                 [| "./lock_holder.exe"; main_root; "d" |]
                 to_holder from_holder Unix.stderr
             in
             Unix.close to_holder;
             Unix.close from_holder;
             p "after a publish lock, another process: %s\n"
               (input_line (Unix.in_channel_of_descr holder_out));
             Unix.close holder_in;
             ignore (Unix.waitpid [] pid)));
      p "\n== a copy without queued deletion refuses a collection\n";
      let remote =
        {
          (Local.create ~name:"bucket" (Filename.concat root "bucket")) with
          local_path = None;
          bucket_functions = true;
        }
      in
      let c2 =
        Composite.create ~domain:d
          ~data_dir:(Filename.concat root "data2")
          ~owner:true ~poke:ignore ~knowledge
          [
            { name = "main"; role = Main; store = main };
            { name = "bucket"; role = Backfill; store = remote };
          ]
      in
      p "collect: %s\n"
        (match Collector.run c2 with
          | Error (Unsupported r) -> "refused: " ^ r
          | Error Busy -> "busy"
          | Error (Refused r) -> "refused: " ^ r
          | Ok _ -> "ran");
      p "abort: %s\n"
        (match Collector.run ~keep:true c2 with
          | Ok _ -> "allowed"
          | Error _ -> "refused");
      p "dry run: %s\n"
        (match Collector.dry_run c2 with
          | Ok [Ok s] ->
              String.concat ", "
                (List.map (fun (n, k) -> Printf.sprintf "%s %d" n k) s.per_copy)
          | _ -> "failed");
      p "\n== a remote copy that deletes a batch in a request is collected\n";
      let peer =
        {
          (Local.create ~name:"peer" (Filename.concat root "peer")) with
          local_path = None;
        }
      in
      let c3 =
        Composite.create ~domain:d
          ~data_dir:(Filename.concat root "data3")
          ~owner:true ~poke:ignore ~knowledge
          [
            { name = "main"; role = Main; store = main };
            { name = "peer"; role = Backfill; store = peer };
          ]
      in
      p "collect: %s\n"
        (match Collector.run c3 with
          | Error (Unsupported r) -> "refused: " ^ r
          | Error Busy -> "busy"
          | Error (Refused r) -> "refused: " ^ r
          | Ok _ -> "ran"));
  Test_support.finish root
