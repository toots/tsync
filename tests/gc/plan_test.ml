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
  | Open { started; after; marking } ->
      Printf.sprintf "open (started %s), mark after %S%s"
        (Option.fold ~none:"now" ~some:(Printf.sprintf "%.0f") started)
        after
        (if marking then ", no rename" else "")

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
  p "\n== versions (§4.1): cutoff 2 s\n";
  p "deleted: %s\n"
    (keys
       (Gc_plan.versions ~cutoff:2.
          [
            k "tsync/d/versions/a/h/1000000000";
            k "tsync/d/versions/a/h/2000000000";
            k "tsync/d/versions/a/h/3000000000";
            k "tsync/d/versions/a/h/notatime";
          ]));
  p "\n== log (publication §4.9): now day 100, retention 30 days\n";
  let day = 86400. in
  let entries = List.map (fun (n, age) -> (Key.log_entry d n, age *. day)) in
  let show l =
    match l with
      | [] -> "nothing"
      | l ->
          String.concat " "
            (List.map
               (fun key -> string_of_int (int_of_string (Key.leaf key)))
               l)
  in
  List.iter
    (fun (name, tree_head, es) ->
      p "%-52s -> %s\n" name
        (show
           (Gc_plan.log ~now:(100. *. day) ~retention:(30. *. day) ~tree_head
              (entries es))))
    [
      ( "entries 1 to 5, all old, tree head 5: the head stays",
        5,
        [(1, 10.); (2, 20.); (3, 30.); (4, 40.); (5, 50.)] );
      ( "tree head 3: nothing above it goes",
        3,
        [(1, 10.); (2, 20.); (3, 30.); (4, 40.); (5, 50.)] );
      ( "entries 2 and 3 younger than the retention",
        5,
        [(1, 10.); (2, 80.); (3, 90.); (4, 40.); (5, 50.)] );
      ("one entry, old: it is the head", 1, [(1, 10.)]);
      ("listed out of order", 5, [(5, 50.); (2, 20.); (1, 10.)]);
    ];
  p "takeovers the tree head (7) has passed: %s\n"
    (String.concat " "
       (List.map Key.leaf
          (Gc_plan.takeovers ~tree_head:7
             [
               Key.takeover d 6 ~generation:1;
               Key.takeover d 7 ~generation:2;
               Key.void d 7;
               Key.takeover d 8 ~generation:1;
               Key.void d 9;
             ])));
  p "\n== shares (§4.3): now 100\n";
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
