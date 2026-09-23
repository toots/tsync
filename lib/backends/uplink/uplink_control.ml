type settings = {
  enabled : bool;
  headroom : float;
  target_delay : float;
  min_rate : int;
  max_rate : int option;
}

let default_settings =
  {
    enabled = true;
    headroom = 0.8;
    target_delay = 0.05;
    min_rate = 65536;
    max_rate = None;
  }

let initial_rate = ref 262144.
let tick_interval = ref 2.
let probe_timeout = ref 10.
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

type limit = Configured | Measured | Estimating

let string_of_limit = function
  | Configured -> "configured"
  | Measured -> "measured"
  | Estimating -> "estimating"

let limit_of_string = function
  | "configured" -> Some Configured
  | "measured" -> Some Measured
  | "estimating" -> Some Estimating
  | _ -> None

(* A rolling aggregate over fixed periods, keyed on the time handed in rather
   than the wall's, so a test can turn it. *)
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

  (* Into the period [ago] periods back, if the ring still holds it. *)
  let note_back t ~now ~ago v =
    advance t now;
    let n = Array.length t.cells in
    if ago < n then begin
      let i = (t.at - ago) mod n in
      let i = if i < 0 then i + n else i in
      t.cells.(i) <- t.combine t.cells.(i) v
    end

  let fold t ~now =
    advance t now;
    Array.fold_left t.combine t.empty t.cells
end

type t = {
  settings : settings;
  mutable rate : float;
  bases : (string, Window.t) Hashtbl.t;
  completed_bytes : Window.t;
  mutable capacity : float option;
  mutable samples : (string * float) list;
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

let cells_of span width = Int.max 1 (int_of_float (span /. width))

let create ?(settings = default_settings) ~now () =
  {
    settings;
    rate = clamp_to_settings settings !initial_rate;
    bases = Hashtbl.create 2;
    completed_bytes =
      Window.create ~cells:(cells_of !rate_window 1.) ~width:1. ~empty:0.
        ~combine:( +. ) ~now;
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

let dropped t = t.drops <- t.drops + 1

(* Credited over the seconds the body took, not the one it landed in: a body
   longer than the window would otherwise read as a burst of its whole size
   and then as nothing, and the link as far larger than it is. *)
let completed t ~now ~bytes ~elapsed =
  let seconds = Int.max 1 (int_of_float (Float.ceil elapsed)) in
  let each = float_of_int bytes /. float_of_int seconds in
  for ago = 0 to seconds - 1 do
    Window.note_back t.completed_bytes ~now ~ago each
  done

let observe_delay ?(path = "") t ~now:_ delay =
  t.samples <- (path, delay) :: t.samples

let achieved t ~now = Window.fold t.completed_bytes ~now /. !rate_window
let rate t = t.rate
let state t = t.state
let capacity t = t.capacity

let base_delay t ~now =
  let b =
    Hashtbl.fold
      (fun _ w acc -> Float.min acc (Window.fold w ~now))
      t.bases infinity
  in
  if b < infinity then Some b else None

let queueing_delay t = t.queueing
let drops t = t.drops

let enter t ~now state =
  t.state <- state;
  t.since <- now;
  t.settled <- false

(* A ramp that met the edge is a fresh measurement of it, and replaces what
   an older one said. The link can carry at least what completed meanwhile,
   and not much more than twice it: a step that built no queue only says the
   link kept up with what was offered, and a sender with one body in flight
   at a time offers far less than its rate, so between two steps the edge is
   bounded by what got through as much as by the steps. *)
let measured_capacity t ~now estimate =
  let achieved = achieved t ~now in
  let bounded =
    if achieved > 0. then Float.min estimate (2. *. achieved) else estimate
  in
  t.capacity <- Some (Float.max achieved bounded)

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

let set_rate t rate =
  t.rate <- clamp_to_settings t.settings (Float.min rate (ceiling t))

let timed_out t ~now =
  lower_capacity t ~now;
  t.never_saturated <- false;
  enter t ~now Backing_off;
  set_rate t (t.rate *. !decrease_floor)

let base_of t ~now path =
  match Hashtbl.find_opt t.bases path with
    | Some w -> w
    | None ->
        let w =
          Window.create
            ~cells:(cells_of !base_window 60.)
            ~width:60. ~empty:infinity ~combine:Float.min ~now
        in
        Hashtbl.replace t.bases path w;
        w

(* Each path above its own base, since stores sharing a link sit at different
   distances and the far one alone would read its distance as a queue.

   The least of those, smoothed over two ticks, decays toward nothing on a tick
   with no probe rather than holding a reading no longer being taken. *)
let read_delay t ~now =
  (match t.samples with
    | [] -> t.queueing <- 0.5 *. t.queueing
    | samples ->
        let above (path, delay) =
          let w = base_of t ~now path in
          Window.note w ~now delay;
          Float.max 0. (delay -. Window.fold w ~now)
        in
        let current =
          List.fold_left (fun acc s -> Float.min acc (above s)) infinity samples
        in
        t.queueing <- (0.5 *. t.queueing) +. (0.5 *. current));
  t.samples <- []

let tick t ~now ~limited =
  read_delay t ~now;
  let target = t.settings.target_delay in
  let q = t.queueing in
  t.over_target <- (if q > target then t.over_target + 1 else 0);
  let off = Float.max (-1.) (Float.min 1. ((target -. q) /. target)) in
  (* Held back, and using the link: a body waiting out a debt on an idle
     link is no reason to grant more. *)
  let limited = limited && achieved t ~now > 0. in
  let rate = t.rate in
  let next =
    match t.state with
      | Ramping ->
          (* Two ticks over target, as the ratchet asks: one probe behind one
             body reads a queue that is gone by the next, and a ramp ended on
             it learns a link a fraction of the size. *)
          if q > target && t.over_target >= 2 then begin
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
          else if q <= target /. 2. && limited then
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
          (* Growth only for a sender the rate held back; a shrink always. *)
          if off > 0. && not limited then rate
          else rate *. (1. +. (!gain *. off))
      | Backing_off ->
          if now -. t.since >= !backoff_hold then enter t ~now Ramping;
          rate
  in
  set_rate t next

(* What holds the rate where it is. A configured ceiling says so once the rate
   has reached it, whatever the law knows of the link: raising it is the
   owner's call, not something the link will answer. *)
let limit t =
  match t.settings.max_rate with
    | Some m when t.rate >= float_of_int m *. 0.999 -> Configured
    | _ -> ( match t.capacity with Some _ -> Measured | None -> Estimating)

let json t ~now =
  let ms s = `Float (Float.round (s *. 10_000.) /. 10.) in
  [
    ("enabled", `Bool t.settings.enabled);
    ("state", `String (string_of_state t.state));
    ("limit", `String (string_of_limit (limit t)));
    ( "maxRateBytesPerSec",
      match t.settings.max_rate with Some m -> `Int m | None -> `Null );
    ("rateBytesPerSec", `Int (int_of_float (rate t)));
    ( "capacityBytesPerSec",
      match t.capacity with Some c -> `Int (int_of_float c) | None -> `Null );
    ( "baseDelayMs",
      match base_delay t ~now with Some b -> ms b | None -> `Null );
    ("queueingDelayMs", ms t.queueing);
    ("drops", `Int t.drops);
    ("headroom", `Float t.settings.headroom);
    ("targetDelayMs", ms t.settings.target_delay);
  ]
