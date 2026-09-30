open Tsync_core
open Tsync_store
module B = Uplink.Budget

let p fmt = Printf.printf (fmt ^^ "\n%!")

let () =
  p "== budget (uplink-governor §4.2), 1000 B/s: burst 2000, window 30000";
  let b = B.create ~rate:1000. ~now:0. in
  p "admits 1500 at 0: %b" (B.admits b ~now:0. 1500);
  B.take b ~now:0. 1500;
  p "admits 1000 at 0: %b, waits %.2fs" (B.admits b ~now:0. 1000)
    (B.wait_for b ~now:0. 1000);
  p "admits 1000 at 0.5: %b" (B.admits b ~now:0.5 1000);
  B.release b 1500;
  let big = B.create ~rate:1000. ~now:0. in
  p "a body over the bucket alone: %b" (B.admits big ~now:0. 50_000);
  B.take big ~now:0. 50_000;
  p "then the window blocks: waits %s"
    (let w = B.wait_for big ~now:100. 100 in
     if w = infinity then "until a completion" else string_of_float w);
  B.release big 50_000;
  p "after its completion, debt paid by 100s: %b" (B.admits big ~now:100. 100);
  p "== gate at 1 MiB/s";
  Rt.run_sync (fun () ->
      let link =
        let mib = 1024. *. 1024. in
        Uplink.link "test"
          {
            enabled = true;
            law =
              {
                headroom = 0.8;
                target_delay = 0.05;
                min_rate = mib;
                max_rate = Some mib;
              };
          }
      in
      let t0 = Rt.now () in
      List.iter
        (fun _ ->
          let tk = Uplink.acquire link (512 * 1024) in
          Uplink.completed link tk)
        (List.init 8 Fun.id);
      let took = Rt.now () -. t0 in
      p "4 MiB in 512 KiB bodies: %s"
        (if took > 1.6 && took < 2.8 then "about 2 s (the burst is 2 s of rate)"
         else Printf.sprintf "%.2fs" took);
      p "a best-effort body beyond the budget: %s"
        (match Uplink.try_acquire link (8 * 1024 * 1024) with
          | Some _ -> "admitted"
          | None -> "refused");
      p "a disabled link admits at once: %b"
        (let u =
           Uplink.link "open"
             {
               enabled = false;
               law =
                 {
                   headroom = 0.8;
                   target_delay = 0.05;
                   min_rate = 1.;
                   max_rate = None;
                 };
             }
         in
         Uplink.try_acquire u (1 lsl 40) <> None))

module Lease = Uplink_lease

let grants rows =
  let g = Lease.split ~total:1000. ~min_rate:100. ~interval:2. rows in
  String.concat " " (List.map (Printf.sprintf "%.0f") g)
  ^ Printf.sprintf " (sum %.0f)" (List.fold_left ( +. ) 0. g)

let () =
  let waiting = { Lease.idle with waiting = 2 } in
  let mover = { Lease.idle with in_flight = 10; completed = 200. } in
  p "== lease split (§4.5), 1000 B/s, min_rate 100, interval 2 s";
  p "three waiting: %s" (grants [waiting; waiting; waiting]);
  p "waiting, idle: %s" (grants [waiting; Lease.idle]);
  p "waiting, mover at 100 B/s: %s" (grants [waiting; mover]);
  p "idle, idle: %s" (grants [Lease.idle; Lease.idle]);
  p "held back counts as waiting: %s"
    (grants [{ Lease.idle with held_back = true }; Lease.idle]);
  p "floors fit a small link: %s"
    (let g =
       Lease.split ~total:150. ~min_rate:100. ~interval:2.
         [Lease.idle; Lease.idle; waiting]
     in
     String.concat " " (List.map (Printf.sprintf "%.0f") g));
  p "== renewal shapes";
  let show j = p "  %s" (Yojson.Safe.to_string j) in
  let report =
    {
      mover with
      timeouts = 1;
      waiting = 3;
      held_back = true;
      probes = [("gcs", 0.0412)];
    }
  in
  show (Lease.request_to_json ~pid:1234 [("wan", report)]);
  let read j =
    match Lease.request_of_json (Yojson.Safe.from_string j) with
      | None -> p "  refused"
      | Some r ->
          List.iter
            (fun (l, (x : Lease.report)) ->
              p "  pid %d flat %b %s: inFlight %d heldBack %b probes [%s]" r.pid
                r.flat l x.in_flight x.held_back
                (String.concat ", "
                   (List.map
                      (fun (s, d) -> Printf.sprintf "%S %.4f" s d)
                      x.probes)))
            r.links
  in
  read
    (Yojson.Safe.to_string (Lease.request_to_json ~pid:1234 [("wan", report)]));
  p "an old flat report, without heldBack or probesMs:";
  read {|{"action":"uplink","pid":7,"inFlight":5,"completed":0,"probeMs":12.5}|};
  show
    (Lease.answer_to_json ~interval:2. ~flat:true
       [("wan", { Lease.rate = 1250000.; limit = "measured" })]);
  let answer j =
    match Lease.answer_of_json (Yojson.Safe.from_string j) with
      | None -> "refused"
      | Some (i, l) ->
          Printf.sprintf "interval %.0f, %s" i
            (String.concat ", "
               (List.map (fun (k, r) -> Printf.sprintf "%s %.0f" k r) l))
  in
  p "answer with links: %s"
    (answer
       {|{"ok":true,"interval":2.0,"links":{"wan":{"rate":1250000.0,"limit":"measured"}}}|});
  p "answer without links: %s" (answer {|{"ok":true}|})
