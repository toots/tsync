open Tsync_core
open Tsync_store
module B = Uplink.Budget

let p fmt = Printf.printf (fmt ^^ "\n%!")
let mib = 1024 * 1024

let link name =
  let rate = float_of_int mib in
  Uplink.link name
    {
      enabled = true;
      law =
        {
          headroom = 0.8;
          target_delay = 0.05;
          min_rate = rate;
          max_rate = Some rate;
        };
    }

(* A writer that asks [pace] before each slice, as the HTTP client does. *)
let send ?(on_slice = fun _ -> ()) link ~chunk bytes =
  Uplink.admitted link Wait ~chunk bytes (fun pace ->
      let rec go remaining =
        if remaining > 0 then (
          let len =
            Option.fold ~none:remaining ~some:(fun pace -> pace remaining) pace
          in
          on_slice len;
          go (remaining - len))
      in
      go bytes)

let () =
  p "== budget (uplink-governor §4.2), 1000 B/s: burst 2000, window 30000";
  let b = B.create ~rate:1000. ~now:0. in
  p "admits 1500 at 0: %b" (B.admits b ~now:0. ~chunk:false 1500);
  B.take b ~now:0. ~chunk:false 1500;
  p "admits 1000 at 0: %b, waits %.2fs"
    (B.admits b ~now:0. ~chunk:false 1000)
    (B.wait_for b ~now:0. 1000);
  p "admits 1000 at 0.5: %b" (B.admits b ~now:0.5 ~chunk:false 1000);
  B.release b 1500;
  let big = B.create ~rate:1000. ~now:0. in
  p "a body over the bucket alone: %b"
    (B.admits big ~now:0. ~chunk:false 50_000);
  B.take big ~now:0. ~chunk:false 50_000;
  p "then the window blocks: %b" (not (B.fits big 100));
  B.release big 50_000;
  p "after its completion, debt paid by 100s: %b"
    (B.admits big ~now:100. ~chunk:false 100);
  let c = B.create ~rate:1000. ~now:0. in
  B.take c ~now:0. ~chunk:true 20_000;
  p "a 20000 B chunk takes only its overhead: %b" (B.spends c ~now:0. 900);
  B.spend c ~now:0. 2000;
  let at_once = B.spends c ~now:0. 1000 in
  let later = B.spends c ~now:2.1 1000 in
  p "its slices pay for its bytes: spends 1000 at 0: %b, at 2.1: %b" at_once
    later;
  p "slices: %d at 1000 B/s, %d at 100 MiB/s, %d of 3000 left"
    (B.slice c ~remaining:max_int)
    (let f = B.create ~rate:(100. *. float_of_int mib) ~now:0. in
     B.slice f ~remaining:max_int)
    (B.slice c ~remaining:3000);
  p "== gate at 1 MiB/s";
  Rt.run_sync (fun () ->
      let l = link "test" in
      let t0 = Rt.now () in
      List.iter (fun _ -> send l ~chunk:true (512 * 1024)) (List.init 8 Fun.id);
      let took = Rt.now () -. t0 in
      p "4 MiB in paced 512 KiB chunks: %s"
        (if took > 1.6 && took < 2.8 then "about 2 s (the burst is 2 s of rate)"
         else Printf.sprintf "%.2fs" took);
      p "a best-effort log entry beyond the budget: %s"
        (match Uplink.try_acquire l ~chunk:false (8 * mib) with
          | Some _ -> "admitted"
          | None -> "refused");
      (* The bucket is spent: the chunk below is mid-body, its next slice
         waiting, when the log entry is asked. *)
      let entry_asked = ref infinity and entry_in = ref infinity in
      let late_slices = ref 0 in
      let chunk =
        Rt.async (fun () ->
            send l ~chunk:true mib ~on_slice:(fun _ ->
                let now = Rt.now () in
                if now > !entry_asked && now < !entry_in then incr late_slices))
      in
      Rt.sleep 0.2;
      entry_asked := Rt.now ();
      send l ~chunk:false (256 * 1024) ~on_slice:(fun _ ->
          entry_in := Rt.now ());
      Rt.Promise.await chunk;
      (* One slice granted just before the entry may run just after it. *)
      p "a log entry asked mid-chunk passes before its next slice: %b"
        (!late_slices <= 1 && !entry_in < infinity);
      let order = ref [] and m = Mutex.create () in
      let writer name =
        Rt.async (fun () ->
            send l ~chunk:true (256 * 1024) ~on_slice:(fun _ ->
                Mutex.protect m (fun () -> order := name :: !order)))
      in
      let a = writer 'a' and b = writer 'b' in
      Rt.Promise.await a;
      Rt.Promise.await b;
      let seq = List.rev !order in
      (* After the first writer's burst, while both have slices left: a writer
         woken but not yet asking again can let the other take two in a row. *)
      let rec after_burst = function
        | x :: (y :: _ as rest) when x = y -> after_burst rest
        | l -> l
      in
      let rec until_one_left acc = function
        | x :: rest when List.mem (if x = 'a' then 'b' else 'a') rest ->
            until_one_left (x :: acc) rest
        | _ -> List.rev acc
      in
      let both = until_one_left [] (after_burst seq) in
      let rec longest_run best run = function
        | x :: (y :: _ as rest) ->
            let run = if x = y then run + 1 else 1 in
            longest_run (max best run) run rest
        | _ -> best
      in
      p "two chunks in flight take slices in turn: %b"
        (List.length both > 20 && longest_run 1 1 both <= 2);
      (* A few hundred KiB back in the bucket: its overhead fits, the body
         does not. *)
      Rt.sleep 0.3;
      p "a best-effort chunk larger than what the bucket holds: %s"
        (match Uplink.try_acquire l ~chunk:true (2 * mib) with
          | Some tk ->
              Uplink.abandoned l tk;
              "admitted"
          | None -> "refused");
      (* 1 MiB/s gives a 30 MiB window: one chunk fills it, then a log entry
         waits for the window while that chunk still has slices to write. *)
      let w = link "window" in
      let big = Uplink.acquire w ~chunk:true ((30 * mib) - 4096) in
      let entry =
        Rt.async (fun () ->
            Uplink.completed w (Uplink.acquire w ~chunk:false mib))
      in
      Rt.sleep 0.05;
      p "a log entry held by a full window lets the chunk's slices go: %s"
        (match
           Rt.with_timeout 3. (fun () ->
               for _ = 1 to 20 do
                 ignore (Uplink.pace w big ~remaining:mib)
               done)
         with
          | () -> "true"
          | exception Rt.Timeout -> "false, stuck");
      Uplink.completed w big;
      p "  and is admitted once the chunk completes: %b"
        (match Rt.with_timeout 3. (fun () -> Rt.Promise.await entry) with
          | () -> true
          | exception Rt.Timeout -> false);
      (* A large log entry waits for the bucket; a small one asked after it must
         not pass it. *)
      let f = link "fifo" in
      Uplink.completed f (Uplink.acquire f ~chunk:false (2 * mib));
      let asked bytes =
        let r =
          Rt.async (fun () ->
              let tk = Uplink.acquire f ~chunk:false bytes in
              let still_waiting = Uplink.waiting f in
              Uplink.completed f tk;
              still_waiting)
        in
        Rt.sleep 0.05;
        r
      in
      let large = asked mib in
      let small = asked 1024 in
      ignore (Rt.Promise.await large);
      (* A task resumes late, so a count read once admitted can only shrink: a
         small one admitted ahead of the large one sees it still waiting. *)
      p "a large log entry is not passed by a small one asked after it: %b"
        (Rt.Promise.await small = 0);
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
         let tk = Uplink.acquire u ~chunk:true (1 lsl 40) in
         Uplink.pace u tk ~remaining:(1 lsl 40) = 1 lsl 40))

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
  show
    (Lease.request_to_json
       { pid = 1234; links = [("wan", report)]; flat = false });
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
    (Yojson.Safe.to_string
       (Lease.request_to_json
          { pid = 1234; links = [("wan", report)]; flat = false }));
  p "an old flat report, without heldBack or probesMs:";
  read {|{"action":"uplink","pid":7,"inFlight":5,"completed":0,"probeMs":12.5}|};
  show
    (Lease.answer_to_json
       {
         interval = 2.;
         flat = true;
         grants = [("wan", { rate = 1250000.; limit = Measured })];
       });
  let answer j =
    match Lease.answer_of_json (Yojson.Safe.from_string j) with
      | None -> "refused"
      | Some (a : Lease.answer) ->
          Printf.sprintf "interval %.0f, %s" a.interval
            (String.concat ", "
               (List.map
                  (fun (k, (g : Lease.grant)) ->
                    Printf.sprintf "%s %.0f" k g.rate)
                  a.grants))
  in
  p "answer with links: %s"
    (answer
       {|{"ok":true,"interval":2.0,"links":{"wan":{"rate":1250000.0,"limit":"measured"}}}|});
  p "answer without links: %s" (answer {|{"ok":true}|})
