(* Resuming from each interruption point of spec algorithms/gc.md §7, the state
   built on disk as a crash would leave it: every case must end as an
   uninterrupted run does. *)

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

let live = Chunk_key.of_body "live"
and junk = Chunk_key.of_body "junk"

let case root name setup =
  let main_root = Filename.concat root name in
  let file key = Filename.concat main_root (Key.to_string key) in
  let main = Local.create ~name:"main" main_root
  and replica =
    Local.create ~name:"replica" (Filename.concat root (name ^ "-replica"))
  in
  let c =
    Composite.create ~domain:d
      ~data_dir:(Filename.concat root (name ^ "-data"))
      ~owner:true ~poke:ignore
      ~knowledge:
        { Composite.is_index = (fun _ -> false); is_journal = (fun _ -> false) }
      [
        { name = "main"; role = Main; store = main };
        { name = "replica"; role = Replica; store = replica };
      ]
  in
  Composite.start c;
  List.iter
    (fun (ck, body) ->
      main.put (Key.chunk d ck) (Bigstring.of_string body);
      replica.put (Key.chunk d ck) (Bigstring.of_string body))
    [(live, "live"); (junk, "junk")];
  main.put
    (Key.child d Folder_id.root "f")
    (Bigstring.of_string (manifest [live]));
  let rename a b = Unix.rename (file a) (file b) in
  let s_dir = file (Key.v "tsync/d/chunks")
  and f_dir = file (Key.v "tsync/d/chunks.from") in
  let record r = Gc_record.write main d r in
  setup ~main ~c ~rename ~s_dir ~f_dir ~record;
  let rec until_done n =
    match Collector.run ~budget:0. c with
      | Ok [{ outcome = Completed; _ }] -> "completed"
      | Ok [{ outcome = Suspended _; _ }] when n > 0 -> until_done (n - 1)
      | Ok [{ outcome = Halted r; _ }] -> "halted: " ^ r
      | Ok _ -> "did not finish"
      | Error _ -> "refused"
  in
  let outcome = until_done 50 in
  Composite.settle ~timeout:10. c;
  p
    "%-44s %s; live main %b replica %b; junk main %b replica %b; F %b, R %b, G \
     %s\n"
    name outcome
    (main.head_opt (Key.chunk d live) <> None)
    (replica.head_opt (Key.chunk d live) <> None)
    (Fs.exists (file (Key.chunk d junk))
    || Fs.exists (file (Key.chunk_from d junk)))
    (replica.head_opt (Key.chunk d junk) <> None)
    (Fs.exists f_dir)
    (Fs.exists (file (Key.gc_run d)))
    (Option.fold ~none:"unreadable" ~some:string_of_int
       (Gc_generation.read main d))

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-gc-resume-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let started = 1759140000. in
      case root "uninterrupted"
        (fun ~main:_ ~c:_ ~rename:_ ~s_dir:_ ~f_dir:_ ~record:_ -> ());
      case root "Opening written, S not yet renamed"
        (fun ~main:_ ~c:_ ~rename:_ ~s_dir:_ ~f_dir:_ ~record ->
          record { phase = Opening; started; cursor = ""; generation = None });
      case root "renamed, Marking not yet written"
        (fun ~main:_ ~c:_ ~rename:_ ~s_dir ~f_dir ~record ->
          record { phase = Opening; started; cursor = ""; generation = None };
          Unix.rename s_dir f_dir);
      case root "mid namespace, cursor before it"
        (fun ~main:_ ~c:_ ~rename:_ ~s_dir ~f_dir ~record ->
          record { phase = Marking; started; cursor = ""; generation = None };
          Unix.rename s_dir f_dir);
      case root "mid doom: deletions recorded, F not unlinked"
        (fun ~main ~c ~rename:_ ~s_dir ~f_dir ~record ->
          Unix.rename s_dir f_dir;
          ignore
            (Chunk_spaces.promote
               (Chunk_spaces.create (Option.get main.local_path))
               d live);
          Gc_generation.write main d 1;
          record { phase = Closing; started; cursor = ""; generation = Some 1 };
          match Composite.members c with
            | _ :: replica :: _ ->
                Composite.submit_collection_delete c replica
                  ~keys:[Key.chunk d junk]
                  ~run:(Key.run_name started) ~shard:(Chunk_key.shard junk)
                  ~generation:1
            | _ -> ());
      case root "F removed, R not yet deleted"
        (fun ~main ~c ~rename:_ ~s_dir:_ ~f_dir:_ ~record ->
          (* The doom step owes the copy its deletion while the chunk is
             outgoing; here it is gone from the main first, so the delete
             job's restore check cannot find it surviving. *)
          ignore (main.delete (Key.chunk d junk));
          (match Composite.members c with
            | _ :: replica :: _ ->
                Composite.submit_collection_delete c replica
                  ~keys:[Key.chunk d junk]
                  ~run:(Key.run_name started) ~shard:(Chunk_key.shard junk)
                  ~generation:1
            | _ -> ());
          Gc_generation.write main d 1;
          record
            { phase = Closing; started; cursor = "fff"; generation = Some 1 });
      case root "closing record without a generation"
        (fun ~main ~c:_ ~rename:_ ~s_dir ~f_dir ~record ->
          Unix.rename s_dir f_dir;
          ignore
            (Chunk_spaces.promote
               (Chunk_spaces.create (Option.get main.local_path))
               d live);
          Gc_generation.write main d 4;
          record { phase = Closing; started; cursor = ""; generation = None });
      case root "unreadable run record: abandoned"
        (fun ~main ~c:_ ~rename:_ ~s_dir ~f_dir ~record:_ ->
          Unix.rename s_dir f_dir;
          main.put (Key.gc_run d) (Bigstring.of_string "garbage"));
      case root "mid keep_one: a shard half moved back"
        (fun ~main ~c:_ ~rename:_ ~s_dir ~f_dir ~record ->
          Unix.rename s_dir f_dir;
          record { phase = Abandoning; started; cursor = ""; generation = None };
          let root = Option.get main.local_path in
          let spaces = Chunk_spaces.create root in
          ignore (Chunk_spaces.promote spaces d live);
          let f =
            Filename.concat root (Key.to_string (Key.chunk_from d live))
          in
          Fs.write_file_for_test f "live"));
  Fs.rm_rf root
