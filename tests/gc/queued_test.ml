(* Queued deletion on a copy with a bucket function (spec algorithms/gc.md
   §5.7, replication §4.8, object-store-common §3, §5.4). The copy is a local
   store standing in for a bucket, and the function a stand-in that consumes
   requests as lambda/verify.py run_gc_job does; it can be switched off to play
   an undeployed function or a missed notification. *)

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

(* §5.4: only chunk keys of the request's own domain, their markers with them,
   and the request last. *)
let consume (inner : Store.t) request =
  match inner.get_opt request with
    | None -> ()
    | Some body ->
        let keys =
          List.filter
            (fun k ->
              match Key.chunk_parts k with
                | Some (d', _) ->
                    Domain_name.to_string d' = Domain_name.to_string d
                | None -> false)
            (Discards.keys_of_body body)
        in
        inner.delete_multi (keys @ List.filter_map Key.marker_of keys);
        ignore (inner.delete request)

let bucket ~function_on (inner : Store.t) =
  let notify key =
    if Atomic.get function_on && Key.parse_discard_job key <> None then
      Rt.spawn ~name:"bucket function" (fun () ->
          Rt.sleep 0.05;
          consume inner key)
  in
  {
    inner with
    local_path = None;
    bucket_functions = true;
    put =
      (fun ?mode key body ->
        inner.put ?mode key body;
        notify key);
  }

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-gc-queued-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  let main = Local.create ~name:"main" (Filename.concat root "main") in
  let inner = Local.create ~name:"bucket" (Filename.concat root "bucket") in
  let function_on = Atomic.make false in
  let copy = bucket ~function_on inner in
  let names = Hashtbl.create 8 in
  let chunk n =
    let c = Chunk_key.of_body n in
    Hashtbl.replace names (Chunk_key.to_string c) n;
    c
  in
  Rt.run_sync (fun () ->
      let c =
        Composite.create
          ~timing:{ discard_poll = 0.2; probe_poll = 0.05; probe_wait = 0.5 }
          ~domain:d
          ~data_dir:(Filename.concat root "data")
          ~owner:true ~poke:ignore
          ~knowledge:
            {
              Composite.is_index = (fun _ -> false);
              is_journal = (fun _ -> false);
            }
          [
            { name = "main"; role = Main; store = main };
            { name = "bucket"; role = Backfill; store = copy };
          ]
      in
      let member =
        List.find
          (fun (m : Composite.member) -> m.name = "bucket")
          (Composite.members c)
      in
      Composite.start c;
      let put_chunks l =
        List.iter
          (fun n ->
            let key = Key.chunk d (chunk n) and body = Bigstring.of_string n in
            main.put key body;
            inner.put key body)
          l
      in
      let publish leaf l =
        main.put
          (Key.child d Folder_id.root leaf)
          (Bigstring.of_string (manifest (List.map chunk l)))
      in
      let on_bucket n = inner.head_opt (Key.chunk d (chunk n)) <> None in
      let rec until ?(n = 100) f =
        if f () then true
        else if n = 0 then false
        else (
          Rt.sleep 0.1;
          until ~n:(n - 1) f)
      in
      let generation () =
        Option.fold ~none:"unreadable" ~some:string_of_int
          (Gc_generation.read main d)
      in
      let settled () =
        until (fun () ->
            match Gc_generation.read main d with
              | Some g -> g mod 2 = 0
              | None -> false)
      in
      let collect () =
        match Collector.run c with
          | Ok [s] ->
              Printf.sprintf "%s, %d reclaimed"
                (match s.outcome with
                  | Completed -> "completed"
                  | _ -> "not completed")
                s.chunks_reclaimed
          | Ok _ -> "several mains"
          | Error (Unsupported r) -> "refused: " ^ r
          | Error Busy -> "busy"
      in
      let outstanding () =
        String.concat ", "
          (List.map
             (fun (o : Composite.outstanding) ->
               Printf.sprintf "%s %d keys" (Key.leaf o.request) o.keys)
             (Composite.outstanding c))
      in
      put_chunks ["live"; "junk1"; "junk2"];
      publish "a" ["live"];
      p "== no function deployed\n";
      let probed = Composite.probe c member in
      let confirmed = Composite.function_confirmed c member in
      let left = Composite.outstanding c <> [] in
      p "probe: %b; confirmed: %b; probe request left behind: %b\n" probed
        confirmed left;
      p "collect: %s\n" (collect ());
      p "\n== the function deployed\n";
      Atomic.set function_on true;
      let probed = Composite.probe c member in
      let confirmed = Composite.function_confirmed c member in
      p "probe: %b; confirmed: %b\n" probed confirmed;
      p "collect: %s\n" (collect ());
      Composite.settle ~timeout:10. c;
      let ok = settled () in
      let g = generation () in
      let o = outstanding () in
      p "generation settled: %b (%s); requests left: [%s]\n" ok g o;
      let live = on_bucket "live" in
      let j1 = on_bucket "junk1" in
      let j2 = on_bucket "junk2" in
      p "bucket: live %b, junk1 %b, junk2 %b\n" live j1 j2;
      p "\n== a missed notification: the request waits, G stays odd\n";
      Atomic.set function_on false;
      put_chunks ["junk3"];
      p "collect: %s\n" (collect ());
      Composite.settle ~timeout:10. c;
      Rt.sleep 0.5;
      let g = generation () in
      let o = outstanding () in
      let j3 = on_bucket "junk3" in
      p "generation %s; outstanding: [%s]; junk3 on bucket %b\n" g o j3;
      Atomic.set function_on true;
      p "re-delivered: %d\n" (Composite.retry_outstanding c);
      let ok = settled () in
      let g = generation () in
      let o = outstanding () in
      let j3 = on_bucket "junk3" in
      p "generation settled: %b (%s); outstanding: [%s]; junk3 on bucket %b\n"
        ok g o j3;
      p "\n== a chunk referenced again while its request waits is put back\n";
      Atomic.set function_on false;
      put_chunks ["again"];
      p "collect: %s\n" (collect ());
      Composite.settle ~timeout:10. c;
      main.put (Key.chunk d (chunk "again")) (Bigstring.of_string "again");
      publish "b" ["again"];
      Atomic.set function_on true;
      List.iter
        (fun (o : Composite.outstanding) -> consume inner o.request)
        (Composite.outstanding c);
      let ok = settled () in
      p "consumed as written; generation settled: %b (%s)\n" ok (generation ());
      p "restored on bucket: %b\n" (until (fun () -> on_bucket "again"));
      p "\n== two batches of one shard make one request\n";
      Atomic.set function_on false;
      let x = chunk "x1" and y = chunk "y1" in
      List.iter
        (fun ck -> inner.put (Key.chunk d ck) (Bigstring.of_string "z"))
        [x; y];
      let batch ck =
        Composite.submit_collection_delete c member
          ~keys:[Key.chunk d ck]
          ~run:"1790000000000" ~shard:"abc" ~generation:7
      in
      batch x;
      batch y;
      Composite.settle ~timeout:10. c;
      p "outstanding: [%s]\n" (outstanding ()));
  Fs.rm_rf root
