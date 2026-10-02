(* Every retention and collection decision of spec algorithms/gc.md, printed
   for a snapshot; §10's binding parts are what is kept, deleted or refused. *)

open Tsync_core
open Tsync_gc

let p fmt = Printf.printf fmt
let d = Domain_name.v "d"
let k = Key.v

let show_read = function
  | Gc_record.Absent -> "absent"
  | Unreadable -> "unreadable"
  | Record r ->
      Printf.sprintf "%s started=%.3f cursor=%S generation=%s"
        (Gc_record.phase_name r.phase)
        r.started r.cursor
        (Option.fold ~none:"-" ~some:string_of_int r.generation)

let show_start = function
  | Gc_plan.Resume_keep c -> Printf.sprintf "keep after %S" c
  | Begin_keep -> "write abandoning, keep all"
  | Resume_close { after; generation } ->
      Printf.sprintf "close after %S, generation %s" after
        (Option.fold ~none:"fresh" ~some:string_of_int generation)
  | Open { started; after } ->
      Printf.sprintf "open (started %s), mark after %S"
        (Option.fold ~none:"now" ~some:(Printf.sprintf "%.0f") started)
        after

let keys l = String.concat " " (List.map (fun k -> Key.leaf k) l)

let () =
  p "== run record (02 §2.12)\n";
  List.iter
    (fun b -> p "%-62s -> %s\n" b (show_read (Gc_record.decode b)))
    [
      {|{"phase":"marking","started":1759140000.123,"cursor":"m/3f2a"}|};
      {|{"phase":"closing","started":1759140000,"cursor":"a3f","generation":7}|};
      {|{"phase":"reconciling","started":1,"cursor":"a3f"}|};
      {|{"phase":"opening","started":1,"extra":true}|};
      {|{"phase":"sweeping","started":1}|};
      {|{"phase":"closing","started":1,"generation":0}|};
      {|{"started":1}|};
      "not json";
    ];
  let r =
    {
      Gc_record.phase = Closing;
      started = 1759140000.1234;
      cursor = "a3f";
      generation = Some 7;
    }
  in
  p "encode round trip: %b; run name %s\n"
    (Gc_record.decode (Gc_record.encode r) = Record r)
    (Gc_record.run_name r);
  p "\n== where a session starts (§5.5)\n";
  let rec_ phase cursor generation =
    Gc_record.Record { phase; started = 100.; cursor; generation }
  in
  List.iter
    (fun (name, r0) ->
      List.iter
        (fun keep ->
          p "%-22s keep=%-5b -> %s\n" name keep
            (show_start (Gc_plan.start ~r0 ~keep)))
        [false; true])
    [
      ("absent", Gc_record.Absent);
      ("unreadable", Unreadable);
      ("opening", rec_ Opening "" None);
      ("marking m/b", rec_ Marking "m/b" None);
      ("closing a3f gen 7", rec_ Closing "a3f" (Some 7));
      ("closing, no generation", rec_ Closing "a3f" None);
      ("abandoning 0ff", rec_ Abandoning "0ff" None);
    ];
  p "\n== namespaces: m/ before v/, after the cursor, directory prefixes\n";
  let ns =
    Gc_plan.namespaces ~manifests:["b"; ".tsync-root"; "a"] ~versions:["a"]
  in
  p "from the start: %s\n" (String.concat " " (ns ~after:""));
  p "after m/a:      %s\n" (String.concat " " (ns ~after:"m/a"));
  p "after m/b:      %s\n" (String.concat " " (ns ~after:"m/b"));
  p "prefixes: %s %s\n"
    (Key.prefix_to_string (Gc_plan.namespace_prefix d "m/a"))
    (Key.prefix_to_string (Gc_plan.namespace_prefix d "v/a"));
  p "\n== generation\n";
  List.iter
    (fun g ->
      p "G %s -> %s\n"
        (Option.fold ~none:"unreadable" ~some:string_of_int g)
        (match Gc_plan.closing_generation g with
          | Ok g -> "run generation " ^ string_of_int g
          | Error e -> "stop: " ^ e))
    [Some 0; Some 4; Some 5; None];
  p "settled after 5: %d\n" (Gc_plan.settled_generation 5);
  p "\n== doom step: only chunk keys of the shard absent from S (P4)\n";
  let c n = Chunk_key.of_body n in
  let live = c "live" and dead = c "dead" in
  let shard = Chunk_key.shard dead in
  let other =
    List.find
      (fun c -> Chunk_key.shard c <> shard)
      (List.init 64 (fun i -> c (string_of_int i)))
  in
  let doomed =
    Gc_plan.doomed ~shard
      ~names:
        [
          Chunk_key.to_string dead;
          Chunk_key.to_string dead;
          Chunk_key.to_string live;
          Chunk_key.to_string other;
          ".tsync-tmp-abc.tmp";
          "notes.txt";
        ]
      ~in_surviving:(Chunk_key.equal live)
  in
  p "doomed: %s\n"
    (String.concat " "
       (List.map
          (fun x -> if Chunk_key.equal x dead then "dead" else "OTHER")
          doomed));
  p "\n== abandoning one shard\n";
  List.iter
    (fun (s, f) ->
      p "S %4d, F %4d -> %s\n" s f
        (match Gc_plan.keep_plan ~surviving:s ~outgoing:f with
          | Rename_shard -> "rename F's shard"
          | Push_down -> "push S's entries down, then rename"
          | Move_across -> "move F's entries across"))
    [(0, 500); (3, 500); (200, 500); (499, 500)];
  p "shards after 0ff: %s\n"
    (String.concat " "
       (Gc_plan.after ~cursor:"0ff" ["a00"; "000"; "0ff"; "100"]));
  p "\n== trash (§4.1): cutoff 1000\n";
  let entries ages =
    List.mapi
      (fun i a ->
        (k (Printf.sprintf "tsync/d/manifests/.tsync-trash/e%d" i), a))
      ages
  in
  let show_trash = function
    | Gc_plan.Delete_stale l -> "delete stale entries: " ^ keys l
    | Skip_recent -> "skip: trashed again recently"
    | Purge l -> "purge the subtree, then entries: " ^ keys l
    | Refuse_live -> "refuse: live elsewhere"
  in
  List.iter
    (fun (name, anchor, ages, on_demand) ->
      p "%-34s -> %s\n" name
        (show_trash
           (Gc_plan.trash ~anchor ~cutoff:1000. ~on_demand (entries ages))))
    [
      ("live, entries old and new", Gc_plan.Live, [10.; 2000.], false);
      ("live, on demand", Live, [10.], true);
      ("in trash, one entry recent", In_trash, [10.; 2000.], false);
      ("in trash, all old", In_trash, [10.; 20.], false);
      ("no anchor, old", No_anchor, [10.], false);
      ("in trash, recent, on demand", In_trash, [2000.], true);
    ];
  p "purge order: %s\n"
    (String.concat " "
       (List.map Key.prefix_to_string
          (Gc_plan.purge_order
             [
               (Key.prefix "tsync/d/manifests/top/", 0);
               (Key.prefix "tsync/d/manifests/deep/", 2);
               (Key.prefix "tsync/d/manifests/mid/", 1);
               (Key.prefix "tsync/d/manifests/mid2/", 1);
             ])));
  p "\n== versions (§4.3): cutoff 2 s\n";
  p "deleted: %s\n"
    (keys
       (Gc_plan.versions ~cutoff:2.
          [
            k "tsync/d/versions/a/h/1000000000";
            k "tsync/d/versions/a/h/2000000000";
            k "tsync/d/versions/a/h/3000000000";
            k "tsync/d/versions/a/h/notatime";
          ]));
  p "\n== journal (§4.4): now 100 days, horizon 30 days\n";
  let day = 86400. in
  let entry days =
    let e =
      Tsync_sync.Entry_key.make
        ~ms:(Int64.of_float (days *. day *. 1000.))
        ~client:"c"
    in
    (e, Tsync_sync.Entry_key.journal_key d e)
  in
  let es = List.map entry [10.; 50.; 69.; 71.; 99.] in
  let show l =
    String.concat " "
      (List.map
         (fun key ->
           let e, _ = List.find (fun (_, k') -> Key.equal k' key) es in
           Printf.sprintf "day%.0f"
             (Int64.to_float (Tsync_sync.Entry_key.ms e) /. 1000. /. day))
         l)
  in
  List.iter
    (fun (name, cutoff, cursor) ->
      p "%-40s -> %s\n" name
        (show
           (Gc_plan.journal ~now:(100. *. day) ~horizon:(30. *. day)
              ~cutoff:(cutoff *. day) ~cursor es)))
    [
      ("cutoff day 60", 60., None);
      ("cutoff day 100: the horizon holds", 100., None);
      ("cutoff day 60, cursor names day 10", 60., Some (fst (List.hd es)));
    ];
  p "\n== shares (§4.5): now 100\n";
  List.iter
    (fun b ->
      p "%-50s -> %s\n" b
        (match Gc_plan.share ~domain:d ~now:100. b with
          | Expired -> "expired: delete"
          | Kept -> "kept"
          | Other_domain -> "another domain's"
          | Unparseable -> "unparseable: left, reported"))
    [
      {|{"v":1,"expires":50,"domain":"d","type":"file"}|};
      {|{"v":1,"expires":150,"domain":"d","type":"file"}|};
      {|{"v":1,"expires":50,"domain":"e","type":"file"}|};
      {|{"v":1,"domain":"d"}|};
      "garbage";
    ];
  p "\n== dry run survey (§5.9)\n";
  let entry name size =
    {
      Tsync_store.Store.key = Key.chunk d (c name);
      size;
      last_modified = 0.;
      etag = None;
      checksum = None;
    }
  in
  let s =
    Gc_plan.unreferenced
      ~referenced:(fun x -> Chunk_key.equal x (c "a"))
      [entry "a" 10; entry "b" 20; entry "e" 30]
  in
  p "reclaimable %d chunks, %d bytes\n" s.reclaimable s.bytes
