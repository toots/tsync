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
     ~mtime:0. ~chunk_size:cs cks)
    .body

let knowledge =
  {
    Composite.is_index = (fun k -> Key.leaf k = ".tsync-index");
    is_journal = (fun k -> Key.under (Key.journal d) k);
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
      let run ?budget ?verify ?keep ?cancelled () =
        match Collector.run ?budget ?verify ?keep ?cancelled c with
          | Ok [st] ->
              p "run: %s; promoted %d, reclaimed %d (%d bytes)%s\n"
                (outcome st.outcome) st.chunks_promoted st.chunks_reclaimed
                st.bytes_reclaimed
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
      p "\n== exclusion\n";
      let to_holder, holder_in = Unix.pipe ~cloexec:true ()
      and holder_out, from_holder = Unix.pipe ~cloexec:true () in
      let pid =
        Unix.create_process "./lock_holder.exe"
          [| "./lock_holder.exe"; main_root; "d" |]
          to_holder from_holder Unix.stderr
      in
      Unix.close to_holder;
      Unix.close from_holder;
      p "another process: %s\n"
        (input_line (Unix.in_channel_of_descr holder_out));
      ignore (run ());
      Unix.close holder_in;
      ignore (Unix.waitpid [] pid);
      p "after it exits: ";
      ignore (run ());
      let () =
        match
          Chunk_spaces.with_run_lock (Chunk_spaces.create main_root) d
            (fun () -> run ())
        with
          | Ok _ -> ()
          | Error `Busy -> p "the test could not take the lock\n"
      in
      p "\n== a copy without queued deletion refuses a collection\n";
      let remote =
        {
          (Local.create ~name:"bucket" (Filename.concat root "bucket")) with
          local_path = None;
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
          | _ -> "failed"));
  Fs.rm_rf root
