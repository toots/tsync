(* How an owner splits the link among those holding a share of it.

   What is pinned is the rule: a lessee that wants all it can get is given an
   even share, one using less than that keeps a little over what it uses and
   returns the rest, an idle one holds the floor, and what nobody can use is
   handed out anyway. And the bookkeeping around it: silence drops a row,
   deltas are summed once, and a newcomer is not made to wait for a step. *)

open Check

let total = 1_048_576.
let min_rate = 65_536.
let near a b = Float.abs (a -. b) < 1.
let wants = { Uplink_lease.idle with in_flight = 65536; waiting = 4 }
let moving ~completed = { Uplink_lease.idle with in_flight = 65536; completed }
let pct r = Printf.sprintf "%.0f%%" (100. *. r /. total)

let () =
  Uplink_control.tick_interval := 2.;

  case "two lessees that want all they can get halve what the floor leaves";
  let t = Uplink_lease.create () in
  Uplink_lease.record t ~now:0. ~pid:1 wants;
  Uplink_lease.record t ~now:0. ~pid:2 wants;
  Uplink_lease.split t ~now:0. ~total ~min_rate ~self:Uplink_lease.idle;
  let a = Uplink_lease.rate_for t ~now:0. ~pid:1
  and b = Uplink_lease.rate_for t ~now:0. ~pid:2 in
  check "an even share each"
    ~why:(fun () -> pct a ^ " " ^ pct b)
    (near a b && near a ((total -. min_rate) /. 2.));
  check "the idle owner holds the floor"
    ~why:(fun () -> pct (Uplink_lease.own_rate t))
    (near (Uplink_lease.own_rate t) min_rate);

  case "an idle lessee returns its share";
  let t = Uplink_lease.create () in
  Uplink_lease.record t ~now:0. ~pid:1 Uplink_lease.idle;
  Uplink_lease.record t ~now:0. ~pid:2 wants;
  Uplink_lease.split t ~now:0. ~total ~min_rate ~self:Uplink_lease.idle;
  check "to the one that wants it"
    ~why:(fun () -> pct (Uplink_lease.rate_for t ~now:0. ~pid:2))
    (near (Uplink_lease.rate_for t ~now:0. ~pid:2) (total -. (2. *. min_rate)));

  case "a lessee using less than its share keeps a little over, no more";
  let t = Uplink_lease.create () in
  (* 200 KB in a two-second interval: 100 KB/s used. *)
  Uplink_lease.record t ~now:0. ~pid:1 (moving ~completed:200_000);
  Uplink_lease.record t ~now:0. ~pid:2 wants;
  Uplink_lease.split t ~now:0. ~total ~min_rate ~self:Uplink_lease.idle;
  let a = Uplink_lease.rate_for t ~now:0. ~pid:1 in
  check "a quarter over what it used" ~why:(fun () -> pct a) (near a 125_000.);
  check "and the rest to the one with a line"
    ~why:(fun () -> pct (Uplink_lease.rate_for t ~now:0. ~pid:2))
    (near (Uplink_lease.rate_for t ~now:0. ~pid:2) (total -. min_rate -. a));

  case "nobody wants anything: everything is handed out anyway";
  let t = Uplink_lease.create () in
  Uplink_lease.record t ~now:0. ~pid:1 Uplink_lease.idle;
  Uplink_lease.split t ~now:0. ~total ~min_rate ~self:Uplink_lease.idle;
  check "half each, to burst into"
    ~why:(fun () ->
      pct (Uplink_lease.own_rate t)
      ^ " "
      ^ pct (Uplink_lease.rate_for t ~now:0. ~pid:1))
    (near (Uplink_lease.own_rate t) (total /. 2.)
    && near (Uplink_lease.rate_for t ~now:0. ~pid:1) (total /. 2.));

  case "silence for three intervals and a probe's timeout drops a lessee";
  let t = Uplink_lease.create () in
  Uplink_lease.record t ~now:0. ~pid:1 wants;
  Uplink_lease.record t ~now:0. ~pid:2 wants;
  check "a renewal a slow probe held back finds its row still there"
    (List.map fst (Uplink_lease.live t ~now:8.) = [1; 2]);
  Uplink_lease.record t ~now:10. ~pid:2 wants;
  check "at seventeen seconds, only the one heard at ten"
    (List.map fst (Uplink_lease.live t ~now:17.) = [2]);
  check "and its bytes are the only ones in flight"
    (Uplink_lease.in_flight t ~now:17. = 65536);

  case "a newcomer since the last split is granted an even share at once";
  let t = Uplink_lease.create () in
  Uplink_lease.record t ~now:0. ~pid:1 wants;
  Uplink_lease.split t ~now:0. ~total ~min_rate ~self:Uplink_lease.idle;
  Uplink_lease.record t ~now:1. ~pid:2 wants;
  check "a third, between the owner, the one there and itself"
    ~why:(fun () -> pct (Uplink_lease.rate_for t ~now:1. ~pid:2))
    (near (Uplink_lease.rate_for t ~now:1. ~pid:2) (total /. 3.));

  case "what was reported is summed once, then gone";
  let t = Uplink_lease.create () in
  Uplink_lease.record t ~now:0. ~pid:1
    { Uplink_lease.idle with completed = 100; timeouts = 1 };
  Uplink_lease.record t ~now:0. ~pid:2 { Uplink_lease.idle with completed = 50 };
  check "the sum" (Uplink_lease.drain t = (150, 1));
  check "then nothing" (Uplink_lease.drain t = (0, 0));

  case "having waited is said once, and spent by the split that hears it";
  let t = Uplink_lease.create () in
  Uplink_lease.record t ~now:0. ~pid:1
    { Uplink_lease.idle with held_back = true };
  check "heard"
    (List.exists
       (fun (_, r) -> Uplink_lease.wants r)
       (Uplink_lease.live t ~now:0.));
  Uplink_lease.split t ~now:0. ~total ~min_rate ~self:Uplink_lease.idle;
  check "and spent"
    (not
       (List.exists
          (fun (_, r) -> Uplink_lease.wants r)
          (Uplink_lease.live t ~now:0.)));

  case "a lessee that never says is held back while it has a body in flight";
  let old_build = Uplink_lease.report_of_json [("inFlight", `Int 5)] in
  check "read as wanting more" (Uplink_lease.wants old_build);
  check "and one that says no is not"
    (not
       (Uplink_lease.wants
          (Uplink_lease.report_of_json
             [("inFlight", `Int 5); ("heldBack", `Bool false)])));

  case "a report read off a request";
  let r =
    Uplink_lease.report_of_json
      [("inFlight", `Int 5); ("completed", `Float 7.); ("waiting", `Int 2)]
  in
  check
    "fields present are read, absent ones are nothing, but for held back,\n\
    \          which a body in flight stands in for"
    (r
    = {
        Uplink_lease.in_flight = 5;
        completed = 7;
        timeouts = 0;
        waiting = 2;
        held_back = true;
        probes = [];
      });

  case "what a lessee timed travels as milliseconds, and only when it did";
  let r = Uplink_lease.report_of_json [("probeMs", `Float 42.)] in
  check "an older lessee's least is read over no store"
    (r.Uplink_lease.probes = [("", 0.042)]);
  check "absent is none"
    ((Uplink_lease.report_of_json []).Uplink_lease.probes = []);
  let timed =
    {
      Uplink_lease.idle with
      in_flight = 7;
      probes = [("near", 0.0123); ("far", 0.2)];
    }
  in
  check "written and read back"
    (Uplink_lease.report_of_json (Uplink_lease.report_to_json timed) = timed);
  check "and not written when none"
    (not
       (List.mem_assoc "probeMs"
          (Uplink_lease.report_to_json Uplink_lease.idle)));

  report ~expected:21 ()
