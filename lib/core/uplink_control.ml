type settings = {
  enabled : bool;
  headroom : float;
  target_delay : float;
  min_rate : int;
  max_rate : int option;
}

let default_settings =
  {
    enabled = false;
    headroom = 0.8;
    target_delay = 0.05;
    min_rate = 65536;
    max_rate = None;
  }

let initial_rate = ref 262144.
let tick_interval = ref 2.
let gain = ref 0.25
let decrease_floor = ref 0.5
let base_window = ref 600.
let rate_window = ref 10.
let probe_up_every = ref 60.
let backoff_hold = ref 10.

type state = Ramping | Steady | Backing_off

let string_of_state = function
  | Ramping -> "ramping"
  | Steady -> "steady"
  | Backing_off -> "backingOff"

(* A rolling aggregate over fixed periods, keyed on the time handed in: the
   ring {!Metrics.counter} keeps, but driven by the caller's clock rather than
   the wall's, so a test can turn it. *)
module Window = struct
  type t = {
    cells : float array;
    width : float;
    empty : float;
    combine : float -> float -> float;
    mutable at : int;
  }

  let period width now = int_of_float (Float.floor (now /. width))

  let create ~cells ~width ~empty ~combine ~now =
    {
      cells = Array.make cells empty;
      width;
      empty;
      combine;
      at = period width now;
    }

  (* Periods gone by since the last look are emptied, the ring's length at
     most: past that every cell is stale. *)
  let advance t now =
    let p = period t.width now in
    if p > t.at then begin
      let n = Array.length t.cells in
      for i = 1 to Int.min n (p - t.at) do
        t.cells.((t.at + i) mod n) <- t.empty
      done;
      t.at <- p
    end

  let note t ~now v =
    advance t now;
    let i = t.at mod Array.length t.cells in
    t.cells.(i) <- t.combine t.cells.(i) v

  let fold t ~now =
    advance t now;
    Array.fold_left t.combine t.empty t.cells
end

type t = {
  settings : settings;
  budget : Uplink_budget.t;
  base : Window.t;
  completed_bytes : Window.t;
  mutable capacity : float option;
  mutable samples : float list;
  mutable queueing : float;
  mutable over_target : int;
  mutable settled : bool;
  mutable state : state;
  mutable since : float;
  mutable never_saturated : bool;
  mutable drops : int;
}

let settings t = t.settings

let clamp_to_settings s rate =
  let rate = Float.max (float_of_int s.min_rate) rate in
  match s.max_rate with
    | Some m -> Float.min (float_of_int m) rate
    | None -> rate

let create ?(settings = default_settings) ~now () =
  let cells_of span width = Int.max 1 (int_of_float (span /. width)) in
  {
    settings;
    budget =
      Uplink_budget.create ~now
        ~rate:(clamp_to_settings settings !initial_rate);
    base =
      Window.create
        ~cells:(cells_of !base_window 60.)
        ~width:60. ~empty:infinity ~combine:Float.min ~now;
    completed_bytes =
      Window.create
        ~cells:(cells_of !rate_window 1.)
        ~width:1. ~empty:0. ~combine:( +. ) ~now;
    capacity = None;
    samples = [];
    queueing = 0.;
    over_target = 0;
    settled = false;
    state = Ramping;
    since = now;
    never_saturated = true;
    drops = 0;
  }

let admits t ~now ~bytes = Uplink_budget.admits t.budget ~now ~bytes
let take t ~now ~bytes = Uplink_budget.take t.budget ~now ~bytes
let wait_for t ~now ~bytes = Uplink_budget.wait_for t.budget ~now ~bytes
let dropped t = t.drops <- t.drops + 1

let completed t ~now ~bytes ~elapsed:_ =
  Uplink_budget.release t.budget ~bytes;
  Window.note t.completed_bytes ~now (float_of_int bytes)

let abandoned t ~now:_ ~bytes = Uplink_budget.release t.budget ~bytes
let observe_delay t ~now:_ delay = t.samples <- delay :: t.samples
let achieved t ~now = Window.fold t.completed_bytes ~now /. !rate_window
let rate t = Uplink_budget.rate t.budget
let state t = t.state
let capacity t = t.capacity

let base_delay t ~now =
  let b = Window.fold t.base ~now in
  if b < infinity then Some b else None

let queueing_delay t = t.queueing
let in_flight_bytes t = Uplink_budget.in_flight_bytes t.budget
let window_bytes t = Uplink_budget.window_bytes t.budget
let tokens t ~now = Uplink_budget.tokens t.budget ~now
let drops t = t.drops

let enter t ~now state =
  t.state <- state;
  t.since <- now;
  t.settled <- false

(* A ramp that met the edge is a fresh measurement of it, and replaces what
   an older one said; the link can carry at least what completed meanwhile. *)
let measured_capacity t ~now estimate =
  t.capacity <- Some (Float.max (achieved t ~now) estimate)

(* What is completing under a queue is what the link has left for us. *)
let lower_capacity t ~now =
  let achieved = achieved t ~now in
  if achieved > 0. then
    t.capacity <-
      Some
        (match t.capacity with
          | Some c -> Float.min c achieved
          | None -> achieved)

(* The rate a steady sender is held under: headroom below what the link was
   seen to carry. Lifted while ramping, which is how a freed link is found. *)
let ceiling t =
  match (t.state, t.capacity) with
    | Ramping, _ | _, None -> infinity
    | (Steady | Backing_off), Some c -> t.settings.headroom *. c

let set_rate t ~now rate =
  Uplink_budget.set_rate t.budget ~now
    (clamp_to_settings t.settings (Float.min rate (ceiling t)))

let timed_out t ~now =
  lower_capacity t ~now;
  t.never_saturated <- false;
  enter t ~now Backing_off;
  set_rate t ~now (rate t *. !decrease_floor)

(* The least of a tick's probes, above the least seen lately, smoothed over
   two ticks. A tick with no probe decays toward nothing rather than holding a
   reading that is no longer being taken. *)
let read_delay t ~now =
  (match t.samples with
    | [] -> t.queueing <- 0.5 *. t.queueing
    | samples ->
        let current = List.fold_left Float.min infinity samples in
        Window.note t.base ~now current;
        let base = Window.fold t.base ~now in
        let above = Float.max 0. (current -. base) in
        t.queueing <- (0.5 *. t.queueing) +. (0.5 *. above));
  t.samples <- []

let tick t ~now =
  read_delay t ~now;
  let target = t.settings.target_delay in
  let q = t.queueing in
  t.over_target <- (if q > target then t.over_target + 1 else 0);
  let off = Float.max (-1.) (Float.min 1. ((target -. q) /. target)) in
  let rate = rate t in
  let next =
    match t.state with
      | Ramping ->
          if q > target then begin
            (* The edge lies between the last step that built no queue and
               this one that did: their geometric mean, or what completed if
               that says more. A trailing average alone would still hold the
               ramp's early seconds and read the link far too small. *)
            let step = if t.never_saturated then 2. else 1. +. !gain in
            t.never_saturated <- false;
            measured_capacity t ~now (rate /. Float.sqrt step);
            enter t ~now Steady;
            Float.max (rate *. !decrease_floor) (ceiling t)
          end
          else if q <= target /. 2. then
            if t.never_saturated then rate *. 2. else rate *. (1. +. !gain)
          else rate
      | Steady ->
          (* A queue that comes back up under a rate that had proved fine is
             another user taking a share: the link has less for us now. Fine
             has to have been seen first, or the queue the ramp itself built
             would be read as one; and two ticks of it, so one noisy probe
             cannot ratchet the ceiling down. *)
          if q <= target then t.settled <- true
          else if t.settled && t.over_target >= 2 then lower_capacity t ~now;
          if now -. t.since >= !probe_up_every then enter t ~now Ramping;
          rate *. (1. +. (!gain *. off))
      | Backing_off ->
          if now -. t.since >= !backoff_hold then enter t ~now Ramping;
          rate
  in
  set_rate t ~now next

let json t ~now =
  let ms s = `Float (Float.round (s *. 10_000.) /. 10.) in
  [
    ("enabled", `Bool t.settings.enabled);
    ("state", `String (string_of_state t.state));
    ("rateBytesPerSec", `Int (int_of_float (rate t)));
    ( "capacityBytesPerSec",
      match t.capacity with Some c -> `Int (int_of_float c) | None -> `Null );
    ("baseDelayMs", match base_delay t ~now with Some b -> ms b | None -> `Null);
    ("queueingDelayMs", ms t.queueing);
    ("inFlightBytes", `Int (in_flight_bytes t));
    ("windowBytes", `Int (window_bytes t));
    ("drops", `Int t.drops);
    ("headroom", `Float t.settings.headroom);
    ("targetDelayMs", ms t.settings.target_delay);
  ]
