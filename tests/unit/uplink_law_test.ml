open Tsync_store
module L = Uplink_law

let p fmt = Printf.printf (fmt ^^ "\n%!")
let mib = 1024. *. 1024.
let kib = 1024.

let settings ?max_rate ?(min_rate = 64. *. kib) () =
  { L.headroom = 0.8; target_delay = 0.05; min_rate; max_rate }

(* A fluid bottleneck: one FIFO queue drained at [capacity] and shared in
   proportion to what each sender offers, whose buffer holds [buffer_delay]
   seconds before TCP holds the senders back. *)
type link = {
  capacity : float;
  mutable base : float;
  mutable queue : float;
  mutable competitor : float;
}

type sim = {
  law : L.t;
  link : link;
  mutable now : float;
  mutable sent : float;
  mutable worst_cut : float;
}

let sim ?(settings = settings ()) ?law ~capacity () =
  {
    law = (match law with Some l -> l | None -> L.create settings ~now:0.);
    link = { capacity; base = 0.03; queue = 0.; competitor = 0. };
    now = 0.;
    sent = 0.;
    worst_cut = 1.;
  }

let buffer_delay = 0.25

let second s ~demand =
  let l = s.link in
  let own = if demand then L.rate s.law else 0. in
  let offered = own +. l.competitor in
  let drained = Float.min l.capacity (offered +. l.queue) in
  l.queue <-
    Float.min
      (buffer_delay *. l.capacity)
      (Float.max 0. (l.queue +. offered -. l.capacity));
  if offered > 0. then s.sent <- s.sent +. (drained *. own /. offered);
  s.now <- s.now +. 1.

let delay s = s.link.base +. (s.link.queue /. s.link.capacity)

let tick ?(demand = true) ?(probe = true) s =
  second s ~demand;
  second s ~demand;
  if s.sent > 0. then L.completed s.law ~now:s.now s.sent ~elapsed:2.;
  s.sent <- 0.;
  if probe && demand then L.observe_delay s.law "gcs" (delay s);
  let before = L.rate s.law in
  L.tick s.law ~now:s.now ~limited:demand ~busy:demand;
  s.worst_cut <- Float.min s.worst_cut (L.rate s.law /. before)

let run ?demand ?probe s secs =
  for _ = 1 to int_of_float (secs /. 2.) do
    tick ?demand ?probe s
  done

let phase s =
  match L.phase s.law with
    | L.Ramping -> "ramping"
    | Steady -> "steady"
    | Backing_off -> "backing off"

let limit s =
  match L.limit s.law with
    | L.Configured -> "configured"
    | Measured -> "measured"
    | Estimating -> "estimating"

let mbs r = Printf.sprintf "%.2f MiB/s" (r /. mib)
let near a b = Float.abs (a -. b) <= 0.1 *. b

let trace s secs =
  for _ = 1 to int_of_float (secs /. 2.) do
    tick s;
    p "  t=%3.0f rate %-12s queueing %3.0f ms  %s" s.now
      (mbs (L.rate s.law))
      (L.queueing s.law *. 1000.)
      (phase s)
  done

let () =
  p "== cold start on a 4 MiB/s link, headroom 0.8";
  let s = sim ~capacity:(4. *. mib) () in
  trace s 40.;
  p "steady at headroom of the measured capacity: %b, queue drained: %b"
    (near (L.rate s.law) (0.8 *. Option.get (L.capacity s.law)))
    (L.queueing s.law < 0.025);
  p "capacity %s"
    (match L.capacity s.law with Some c -> mbs c | None -> "unknown");
  p "base delay learnt: %.0f ms" (Option.get (L.base_delay s.law) *. 1000.);
  p "limit: %s" (limit s);

  let alone = L.rate s.law in
  p "== a competitor takes half of the link at t=%.0f" s.now;
  s.link.competitor <- 2. *. mib;
  run s 40.;
  p "yields to its share: %s (%b)"
    (mbs (L.rate s.law))
    (L.rate s.law < 2. *. mib);
  s.link.competitor <- 0.;
  let left = s.now in
  let rec recover () =
    tick s;
    if L.rate s.law < 0.9 *. alone && s.now -. left < 300. then recover ()
  in
  recover ();
  p "after it leaves, back within a probe interval and a ramp: %b"
    (s.now -. left <= 60. +. 20.);
  run s 40.;

  p "== a timeout";
  let before = L.rate s.law in
  L.timed_out s.law ~now:s.now;
  p "halves: %b, %s" (near (L.rate s.law) (before /. 2.)) (phase s);
  run s 8.;
  p "holds for 8 s: %s at %b" (phase s) (near (L.rate s.law) (before /. 2.));
  run s 4.;
  p "then ramps: %s" (phase s);
  p "no tick cut more than half: %b" (s.worst_cut >= 0.5 -. 1e-9);

  p "== no growth without demand or completions";
  let s = sim ~capacity:(100. *. mib) () in
  run ~demand:false s 60.;
  p "idle for 60 s: %s" (mbs (L.rate s.law));
  let s = sim ~capacity:(100. *. mib) () in
  for _ = 1 to 30 do
    s.now <- s.now +. 2.;
    L.tick s.law ~now:s.now ~limited:true ~busy:true
  done;
  p "held back, nothing completing: %s" (mbs (L.rate s.law));

  p "== configured ceiling and floor";
  let s = sim ~settings:(settings ~max_rate:mib ()) ~capacity:(10. *. mib) () in
  run s 40.;
  p "maxRate 1 MiB/s on 10 MiB/s: %s, %s" (mbs (L.rate s.law)) (limit s);
  let s = sim ~capacity:(10. *. mib) () in
  for _ = 1 to 20 do
    L.timed_out s.law ~now:s.now;
    run s 2.
  done;
  p "timeouts on every tick stop at minRate: %s" (mbs (L.rate s.law));

  p "== no samples while busy holds the queueing delay";
  let s = sim ~capacity:(4. *. mib) () in
  run s 40.;
  s.link.competitor <- 4. *. mib;
  run s 4.;
  let q = L.queueing s.law in
  run ~probe:false s 10.;
  p "busy, probes held down: %b" (L.queueing s.law = q && q > 0.);
  run ~demand:false s 10.;
  p "idle: drains to %.0f ms" (L.queueing s.law *. 1000.);

  p "== a standing queue does not become the baseline";
  let s = sim ~capacity:(4. *. mib) () in
  run s 40.;
  let base = Option.get (L.base_delay s.law) in
  s.link.base <- s.link.base +. 0.2;
  run s 1200.;
  let risen = Option.get (L.base_delay s.law) -. base in
  p
    "0.2 s of standing delay for 1200 s (two windows) raises the baseline %.0f \
     ms, at most %.0f"
    (risen *. 1000.) (2. *. 50.);

  p "== restart";
  let law =
    L.restore (settings ()) ~now:0. ~capacity:(4. *. mib) ~saved_at:(-3600.)
  in
  let s = sim ~law ~capacity:(4. *. mib) () in
  p "fresh saved state starts at %s" (mbs (L.rate s.law));
  let r0 = L.rate s.law in
  tick s;
  p "then steps ×%.2f" (L.rate s.law /. r0);
  let law =
    L.restore (settings ()) ~now:0. ~capacity:(4. *. mib) ~saved_at:(-90000.)
  in
  p "state older than a day starts cold: %s" (mbs (L.rate law))
