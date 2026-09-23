(* The law, run against a link that is a few numbers.

   The link has a capacity, a base delay, and whatever share of it a foreign
   load takes; what the controller admits queues on it and drains at the share
   left, and the probe reads base plus the queue's length in time. Stepped a
   second at a time, probed and ticked on the controller's own interval, with
   the clock a number handed in: what is pinned is where the rate settles and
   what the delay did on the way, not how long a run took.

   The bounds are wide where the law is a loop: it hunts around its target,
   and the property is the neighbourhood, not the point. *)

open Check

let mb = 1024. *. 1024.
let body = 65536

type link = {
  capacity : float;
  base : float;
  mutable foreign : float;  (** Bytes per second another user is taking. *)
  mutable queue : float;  (** Our bytes waiting on the link. *)
  budget : Uplink_budget.t;  (** What the law's rate is admitted against. *)
}

let fresh_link ~capacity ~base =
  {
    capacity;
    base;
    foreign = 0.;
    queue = 0.;
    budget = Uplink_budget.create ~now:0. ~rate:!Uplink_control.initial_rate;
  }

(* Offer greedily, drain at what the foreign load leaves, and read the probe
   off the queue: one simulated second. *)
let second link t ~now =
  let rec offer () =
    if Uplink_budget.admits link.budget ~now ~bytes:body then begin
      Uplink_budget.take link.budget ~now ~bytes:body;
      link.queue <- link.queue +. float_of_int body;
      offer ()
    end
  in
  offer ();
  let share = Float.max 0. (link.capacity -. link.foreign) in
  let drained = Float.min link.queue share in
  link.queue <- link.queue -. drained;
  if drained > 0. then begin
    Uplink_budget.release link.budget ~bytes:(int_of_float drained);
    Uplink_control.completed t ~now ~bytes:(int_of_float drained) ~elapsed:1.
  end;
  (* A foreign load keeps a little standing queue of its own in the buffer. *)
  let standing = link.foreign *. 0.02 in
  link.base +. ((link.queue +. standing) /. link.capacity)

(* Run [seconds], probing and ticking every interval; answers the rates and
   delays seen at each tick. *)
let run link t ~from ~seconds =
  let rates = ref [] and delays = ref [] in
  for s = 1 to seconds do
    let now = from +. float_of_int s in
    let delay = second link t ~now in
    if Float.rem now !Uplink_control.tick_interval = 0. then begin
      Uplink_control.observe_delay t ~now delay;
      (* The offer is greedy: the rate always held it back. *)
      Uplink_control.tick t ~now ~limited:true;
      Uplink_budget.set_rate link.budget ~now (Uplink_control.rate t);
      rates := Uplink_control.rate t :: !rates;
      delays := delay :: !delays
    end
  done;
  (List.rev !rates, List.rev !delays, from +. float_of_int seconds)

let mean xs = List.fold_left ( +. ) 0. xs /. float_of_int (List.length xs)
let last xs = List.nth xs (List.length xs - 1)
let within lo hi x = lo <= x && x <= hi
let pct x cap = Printf.sprintf "%.0f%% of capacity" (100. *. x /. cap)

let () =
  Uplink_control.tick_interval := 2.;
  Uplink_control.probe_up_every := 60.;
  Uplink_control.backoff_hold := 10.;
  Uplink_budget.stall_timeout := 60.;
  let settings =
    { Uplink_control.default_settings with enabled = true; headroom = 0.8 }
  in
  let cap = 1.6 *. mb in

  case "a cold start doubles while delay stays flat";
  let link = fresh_link ~capacity:cap ~base:0.02 in
  let t = Uplink_control.create ~settings ~now:0. () in
  check "begins at the initial rate"
    (Uplink_control.rate t = !Uplink_control.initial_rate);
  let rates, _, now = run link t ~from:0. ~seconds:6 in
  check "and is ramping" (Uplink_control.state t = Ramping);
  check "twice as much each tick, until the link is found"
    ~why:(fun () -> String.concat " " (List.map (fun r -> pct r cap) rates))
    (List.nth rates 0 = 2. *. !Uplink_control.initial_rate
    && List.nth rates 1 = 4. *. !Uplink_control.initial_rate);

  case "then settles below capacity, with headroom, and the delay comes down";
  let rates, delays, now = run link t ~from:now ~seconds:40 in
  check "steady within forty seconds" (Uplink_control.state t = Steady);
  check "capacity learned near the truth"
    ~why:(fun () ->
      match Uplink_control.capacity t with
        | Some c -> pct c cap
        | None -> "none")
    (match Uplink_control.capacity t with
      | Some c -> within (0.7 *. cap) (1.1 *. cap) c
      | None -> false);
  check "the rate holds at the headroom, not at the edge"
    ~why:(fun () -> pct (last rates) cap)
    (within (0.6 *. cap) (0.85 *. cap) (last rates));
  check "and the queue it built on the way up has drained"
    ~why:(fun () -> Printf.sprintf "%.0f ms" (1000. *. last delays))
    (last delays < link.base +. settings.target_delay);
  let rates, _, now = run link t ~from:now ~seconds:16 in
  check "where it stays"
    ~why:(fun () -> pct (mean rates) cap)
    (within (0.6 *. cap) (0.85 *. cap) (mean rates));

  case "another user arrives: it yields";
  link.foreign <- 0.5 *. cap;
  let rates, delays, now = run link t ~from:now ~seconds:40 in
  let settled_at = List.filteri (fun i _ -> i >= List.length rates - 5) rates in
  check "within forty seconds, under the share that is left"
    ~why:(fun () -> pct (last rates) cap)
    (last rates < 0.5 *. cap);
  check "and around headroom of it, hunting"
    ~why:(fun () -> pct (mean settled_at) cap)
    (within (0.2 *. cap) (0.5 *. cap) (mean settled_at));
  check "the delay it added is back under target"
    ~why:(fun () -> Printf.sprintf "%.0f ms" (1000. *. last delays))
    (last delays -. link.base -. (link.foreign *. 0.02 /. cap)
    < settings.target_delay);

  case "the other user leaves: it finds the room again on its next probe";
  link.foreign <- 0.;
  let _, _, now = run link t ~from:now ~seconds:70 in
  let rates, _, now = run link t ~from:now ~seconds:30 in
  check "back to headroom of the whole link within a probe interval or two"
    ~why:(fun () -> pct (last rates) cap)
    (within (0.6 *. cap) (0.9 *. cap) (last rates));

  case "a timeout cuts the rate and holds it";
  let before = Uplink_control.rate t in
  Uplink_control.timed_out t ~now;
  check "cut to the floor" (Uplink_control.rate t = before *. 0.5);
  check "and backing off" (Uplink_control.state t = Backing_off);
  let rates, _, now = run link t ~from:now ~seconds:8 in
  check "no growth for the hold" (last rates <= before *. 0.5);
  let _, _, _ = run link t ~from:now ~seconds:4 in
  check "then ramping again"
    (Uplink_control.state t = Ramping || Uplink_control.state t = Steady);

  case "the rate never leaves its settings";
  let floor_rate = 300_000 and ceiling_rate = 500_000 in
  let narrow =
    { settings with min_rate = floor_rate; max_rate = Some ceiling_rate }
  in
  let link = fresh_link ~capacity:cap ~base:0.02 in
  let t = Uplink_control.create ~settings:narrow ~now:0. () in
  let rates, _, now = run link t ~from:0. ~seconds:60 in
  check "under a ceiling, it stops there"
    ~why:(fun () -> pct (last rates) cap)
    (List.for_all (fun r -> r <= float_of_int ceiling_rate) rates
    && last rates = float_of_int ceiling_rate);
  Uplink_control.timed_out t ~now;
  Uplink_control.timed_out t ~now;
  Uplink_control.timed_out t ~now;
  check "and however many timeouts, not below the floor"
    (Uplink_control.rate t = float_of_int floor_rate);

  case "a sender with little to send is granted no more";
  let t = Uplink_control.create ~settings ~now:0. () in
  let before = Uplink_control.rate t in
  for i = 1 to 20 do
    let now = 2. *. float_of_int i in
    Uplink_control.observe_delay t ~now 0.02;
    Uplink_control.tick t ~now ~limited:false
  done;
  check "forty seconds of flat delay, and the rate has not moved"
    ~why:(fun () -> string_of_float (Uplink_control.rate t))
    (Uplink_control.rate t = before);
  Uplink_control.observe_delay t ~now:42. 0.02;
  Uplink_control.tick t ~now:42. ~limited:true;
  check "held back with nothing completing, still not"
    (Uplink_control.rate t = before);
  Uplink_control.completed t ~now:43. ~bytes:65536 ~elapsed:1.;
  Uplink_control.observe_delay t ~now:44. 0.02;
  Uplink_control.tick t ~now:44. ~limited:true;
  check "held back while sending, it grows"
    (Uplink_control.rate t = 2. *. before);

  case "a body is credited over the seconds it took";
  Uplink_control.rate_window := 10.;
  let t = Uplink_control.create ~settings ~now:0. () in
  (* Eight megabytes that took sixteen seconds: half a megabyte a second,
     of which the window holds ten seconds' worth. *)
  Uplink_control.completed t ~now:16. ~bytes:(8 * 1024 * 1024) ~elapsed:16.;
  Uplink_control.observe_delay t ~now:16. 0.02;
  Uplink_control.tick t ~now:16. ~limited:true;
  Uplink_control.observe_delay t ~now:18. 0.5;
  Uplink_control.tick t ~now:18. ~limited:true;
  Uplink_control.observe_delay t ~now:20. 0.5;
  Uplink_control.tick t ~now:20. ~limited:true;
  check "the edge it then meets reads the link at what got through, not a burst"
    ~why:(fun () ->
      match Uplink_control.capacity t with
        | Some c -> Printf.sprintf "%.0f KB/s" (c /. 1024.)
        | None -> "none")
    (match Uplink_control.capacity t with
      | Some c -> within (0.25 *. mb) (0.6 *. mb) c
      | None -> false);

  case "steady, and not held back: the rate holds rather than grows";
  let link = fresh_link ~capacity:cap ~base:0.02 in
  let t = Uplink_control.create ~settings ~now:0. () in
  let _, _, now = run link t ~from:0. ~seconds:46 in
  check "steady" (Uplink_control.state t = Steady);
  let before = Uplink_control.rate t in
  Uplink_control.observe_delay t ~now:(now +. 2.) 0.02;
  Uplink_control.tick t ~now:(now +. 2.) ~limited:false;
  check "flat delay, nobody waiting: unchanged" (Uplink_control.rate t = before);
  Uplink_control.observe_delay t ~now:(now +. 4.) 0.2;
  Uplink_control.tick t ~now:(now +. 4.) ~limited:false;
  check "a queue still shrinks it" (Uplink_control.rate t < before);

  case "the base re-learns a route that got shorter";
  let t = Uplink_control.create ~settings ~now:0. () in
  Uplink_control.observe_delay t ~now:0. 0.100;
  Uplink_control.tick t ~now:0. ~limited:false;
  check "the first probe is the base"
    (Uplink_control.base_delay t ~now:0. = Some 0.100);
  Uplink_control.observe_delay t ~now:2. 0.060;
  Uplink_control.tick t ~now:2. ~limited:false;
  check "a shorter one at once"
    (Uplink_control.base_delay t ~now:2. = Some 0.060);
  Uplink_control.observe_delay t ~now:4. 0.140;
  Uplink_control.tick t ~now:4. ~limited:false;
  check "a longer one is queueing, not a new base"
    (Uplink_control.base_delay t ~now:4. = Some 0.060
    && Uplink_control.queueing_delay t > 0.);
  let later = 4. +. !Uplink_control.base_window +. 60. in
  Uplink_control.observe_delay t ~now:later 0.140;
  Uplink_control.tick t ~now:later ~limited:false;
  check "until the old base has fallen out of the window"
    (Uplink_control.base_delay t ~now:later = Some 0.140);

  report ~expected:29 ()
