open Tsync_core
open Tsync_store

let p = Contract.p
let k = Key.v
let d = Domain_name.v "d"

(* A member that can be switched off: every call fails as a link would. *)
let switchable (s : Store.t) =
  let up = ref true in
  let g f = if !up then f () else Fail.raise_ Fail.Link "%s is down" s.name in
  ( up,
    {
      s with
      put = (fun ?mode key b -> g (fun () -> s.put ?mode key b));
      put_if_absent = (fun key b -> g (fun () -> s.put_if_absent key b));
      get_opt = (fun key -> g (fun () -> s.get_opt key));
      head_opt = (fun key -> g (fun () -> s.head_opt key));
      delete = (fun key -> g (fun () -> s.delete key));
      list_prefix =
        (fun ?max_keys pr -> g (fun () -> s.list_prefix ?max_keys pr));
      get_many = Some (fun keys -> g (fun () -> List.map s.get_opt keys));
    } )

let manifest_body cks =
  let cs = Chunking.chunk_size_min in
  (Manifest.make ~name:"f"
     ~size:(List.length cks * cs)
     ~mtime:0. ~chunk_size:cs cks)
    .body

let knowledge =
  {
    Composite.is_index =
      (fun key -> String.ends_with ~suffix:".tsync-index" (Key.to_string key));
    is_journal =
      (fun key -> Key.under (Key.journal d) key || Key.equal key (Key.cursor d));
  }

let show = function Some s -> Printf.sprintf "%S" s | None -> "none"
let kind f = Contract.kind_of f

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-comp-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  let loc n = Local.create ~name:n (Filename.concat root n) in
  Rt.run_sync (fun () ->
      let main_up, main = switchable (loc "main") in
      let replica = loc "replica"
      and backfill = loc "backfill"
      and archive = loc "archive" in
      let c =
        Composite.create ~domain:d
          ~data_dir:(Filename.concat root "data")
          ~owner:true ~poke:ignore ~knowledge
          [
            { name = "main"; role = Main; store = main };
            { name = "replica"; role = Replica; store = replica };
            { name = "backfill"; role = Backfill; store = backfill };
            { name = "archive"; role = Read_only; store = archive };
          ]
      in
      let s = Composite.store c in
      p "== reads\n";
      Contract.put replica (k "tsync/d/only-on-replica") "stale";
      Contract.put archive (k "tsync/d/old") "archived";
      p "main misses, replica not asked: %s\n"
        (show (Contract.get s (k "tsync/d/only-on-replica")));
      p "archive answers a source miss: %s\n"
        (show (Contract.get s (k "tsync/d/old")));
      p "but is never asked for a checksum: %s\n"
        (match s.compute_checksum (k "tsync/d/old") Checksum.md5 with
          | Some _ -> "some"
          | None -> "none");
      main_up := false;
      p "main down, replica answers: %s\n"
        (show (Contract.get s (k "tsync/d/only-on-replica")));
      p "main down, absent on replica and archive: %s\n"
        (kind (fun () -> Contract.get s (k "tsync/d/nowhere")));
      p "\n== writes with the main down\n";
      p "put: %s\n" (kind (fun () -> Contract.put s (k "tsync/d/x") "x"));
      p "replica owes nothing: %d records\n"
        (List.fold_left
           (fun a (s : Composite.copy_stats) -> a + s.owed)
           0 (Composite.copy_stats c));
      main_up := true;
      p "\n== deferred copies\n";
      let ck1 = Chunk_key.of_body "one" and ck2 = Chunk_key.of_body "two" in
      Contract.put s (Key.chunk d ck1) "one";
      Contract.put s (Key.chunk d ck2) "two";
      let manifest = k "tsync/d/manifests/.tsync-root/aaaa" in
      Contract.put s manifest (manifest_body [ck1; ck2]);
      Contract.put s (k "tsync/d/journal/2026-09/1790000000000-abc") "entry";
      Contract.put s (Key.cursor d) "1790000000000-abc";
      Contract.put s (k "tsync/d/manifests/.tsync-root/.tsync-index") "index";
      p "owed before start: %s\n"
        (String.concat ", "
           (List.map
              (fun (s : Composite.copy_stats) ->
                Printf.sprintf "%s %d" s.copy s.owed)
              (Composite.copy_stats c)));
      Composite.start c;
      Composite.settle ~timeout:10. c;
      p "no copy job left running: %b\n"
        (List.for_all
           (fun (s : Composite.copy_stats) -> s.current = None && s.done_ > 0)
           (Composite.copy_stats c));
      let has (st : Store.t) key = Contract.get st key <> None in
      List.iter
        (fun (n, (st : Store.t)) ->
          p "%s: chunks %b %b, manifest %b, journal %b, cursor %b, index %b\n" n
            (has st (Key.chunk d ck1))
            (has st (Key.chunk d ck2))
            (has st manifest)
            (has st (k "tsync/d/journal/2026-09/1790000000000-abc"))
            (has st (Key.cursor d))
            (has st (k "tsync/d/manifests/.tsync-root/.tsync-index")))
        [("replica", replica); ("backfill", backfill)];
      ignore (s.delete manifest);
      Composite.settle ~timeout:10. c;
      p "after delete, replica manifest %b\n" (has replica manifest);
      p "\n== a manifest naming a chunk no main holds parks, degraded\n";
      let ghost = Chunk_key.of_body "ghost" in
      p "the gate refuses it: %s\n"
        (kind (fun () ->
             Contract.put s
               (k "tsync/d/manifests/.tsync-root/bbbb")
               (manifest_body [ghost])));
      Composite.pause c;
      Contract.put main (Key.chunk d ghost) "ghost";
      Contract.put s
        (k "tsync/d/manifests/.tsync-root/bbbb")
        (manifest_body [ghost]);
      ignore (main.delete (Key.chunk d ghost));
      Composite.resume c;
      Composite.settle ~timeout:10. c;
      List.iter
        (fun (n, _, (note : Dqueue.failure_note)) ->
          p "%s parked: %s\n" n (Fail.kind_name note.last.kind))
        (Composite.parked c);
      p "replica holds it: %b\n"
        (has replica (k "tsync/d/manifests/.tsync-root/bbbb"));
      p "\n== write guard\n";
      main_up := false;
      ignore (Health.lost main.health);
      Unix.sleepf 1.1;
      ignore (Health.lost main.health);
      p "guarded write to the replica: %s\n"
        (kind (fun () ->
             Composite.guard c
               { name = "replica"; role = Replica; store = replica }
               "copy"));
      p "batch read with the main held down: %s\n"
        (kind (fun () -> Option.get s.get_many [k "tsync/d/old"]));
      main_up := true;
      p "\n== conditional replace\n";
      Contract.put main (k "tsync/d/cond") "on main";
      Contract.put replica (k "tsync/d/cond") "on replica";
      p
        "an entry read from another member replaces nothing: %s, main keeps %s\n"
        (match
           s.put_if_unchanged (k "tsync/d/cond")
             (Bigstring.of_string "new")
             (replica.head_opt (k "tsync/d/cond"))
         with
          | Written -> "written"
          | Changed -> "changed")
        (show (Contract.get main (k "tsync/d/cond")));
      p "with the main's entry: %s\n"
        (match
           s.put_if_unchanged (k "tsync/d/cond")
             (Bigstring.of_string "new")
             (main.head_opt (k "tsync/d/cond"))
         with
          | Written -> "written"
          | Changed -> "changed"));
  Fs.rm_rf root
