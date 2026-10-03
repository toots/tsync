type settings = {
  headroom : float;
  target_delay : float;
  min_rate : float;
  max_rate : float option;
}

type phase = Ramping | Steady | Backing_off
type limit = Configured | Measured | Estimating

let initial_rate = 256. *. 1024.
let tick_interval = 2.
let probe_timeout = 10.
let gain = 0.25
let decrease_floor = 0.5
let base_cell = 60.
let base_cells = 10
let base_window = base_cell *. float_of_int base_cells
let rate_window = 10
let probe_up_every = 60.
let backoff_hold = 10.
let restore_fraction = 0.5
let state_max_age = 86400.

type path = {
  mutable cells : (int * float) list;
      (** cell index, least delay, newest first *)
  mutable eff : float;
  mutable eff_changed : float;
}

type t = {
  s : settings;
  mutable rate : float;
  mutable phase : phase;
  mutable since : float;
  mutable settled : bool;
  mutable over_target : int;
  mutable never_saturated : bool;
  mutable capacity : float option;
  mutable queueing : float;
  mutable samples : (string * float) list;
  paths : (string, path) Hashtbl.t;
  mutable done_cells : (int * float) list;  (** second, bytes; newest first *)
}

let clamp s r =
  let r = Float.max s.min_rate r in
  match s.max_rate with Some m -> Float.min m r | None -> r

let create s ~now =
  {
    s;
    rate = clamp s initial_rate;
    phase = Ramping;
    since = now;
    settled = false;
    over_target = 0;
    never_saturated = true;
    capacity = None;
    queueing = 0.;
    samples = [];
    paths = Hashtbl.create 4;
    done_cells = [];
  }

let restore s ~now ~capacity ~saved_at =
  let t = create s ~now in
  if now -. saved_at < state_max_age && capacity > 0. then (
    t.never_saturated <- false;
    t.rate <-
      clamp s
        (Float.max initial_rate (restore_fraction *. s.headroom *. capacity)));
  t

(* A body that took forty seconds counts as forty seconds of throughput, not a
   burst at its end. *)
let completed t ~now bytes ~elapsed =
  let n = max 1 (int_of_float (Float.ceil elapsed)) in
  let per = bytes /. float_of_int n and last = truncate now in
  let add cells s =
    match List.assoc_opt s cells with
      | Some b -> (s, b +. per) :: List.remove_assoc s cells
      | None -> (s, per) :: cells
  in
  let rec spread cells k =
    if k < n then spread (add cells (last - k)) (k + 1) else cells
  in
  t.done_cells <-
    List.filter (fun (s, _) -> s > last - rate_window) (spread t.done_cells 0)

let achieved t ~now =
  let last = truncate now in
  List.fold_left
    (fun acc (s, b) -> if s > last - rate_window then acc +. b else acc)
    0. t.done_cells
  /. float_of_int rate_window

let observe_delay t path d = t.samples <- (path, d) :: t.samples

let enter t p ~now =
  t.phase <- p;
  t.since <- now;
  t.settled <- false

let timed_out t ~now =
  let a = achieved t ~now in
  if a > 0. then
    t.capacity <-
      Some (match t.capacity with Some c -> Float.min c a | None -> a);
  t.never_saturated <- false;
  enter t Backing_off ~now;
  t.rate <- clamp t.s (t.rate *. decrease_floor)

(* §4.4: per path, a sliding minimum over BASE_WINDOW whose effective value
   follows a lower minimum at once and rises by at most the target per window. *)
let filter t ~now ~busy =
  match t.samples with
    | [] -> if not busy then t.queueing <- 0.5 *. t.queueing
    | samples ->
        let cell = int_of_float (now /. base_cell) in
        let above (name, d) =
          let p =
            match Hashtbl.find_opt t.paths name with
              | Some p -> p
              | None ->
                  let p = { cells = []; eff = d; eff_changed = now } in
                  Hashtbl.replace t.paths name p;
                  p
          in
          let cells =
            match p.cells with
              | (c, m) :: rest when c = cell -> (c, Float.min m d) :: rest
              | cells -> (cell, d) :: cells
          in
          p.cells <- List.filter (fun (c, _) -> c > cell - base_cells) cells;
          let m =
            List.fold_left (fun acc (_, x) -> Float.min acc x) infinity p.cells
          in
          if m <= p.eff then (
            p.eff <- m;
            p.eff_changed <- now)
          else (
            let rise =
              t.s.target_delay *. (now -. p.eff_changed) /. base_window
            in
            let eff = Float.min m (p.eff +. rise) in
            if eff > p.eff then (
              p.eff <- eff;
              p.eff_changed <- now));
          Float.max 0. (d -. p.eff)
        in
        let current =
          List.fold_left (fun acc s -> Float.min acc (above s)) infinity samples
        in
        t.queueing <- (0.5 *. t.queueing) +. (0.5 *. current)

let tick t ~now ~limited ~busy =
  filter t ~now ~busy;
  t.samples <- [];
  let target = t.s.target_delay and h = t.s.headroom in
  let q = t.queueing and r = t.rate in
  let a = achieved t ~now in
  t.over_target <- (if q > target then t.over_target + 1 else 0);
  let off = Float.max (-1.) (Float.min 1. ((target -. q) /. target)) in
  let limited = limited && a > 0. in
  let next =
    match t.phase with
      | Ramping ->
          if q > target && t.over_target >= 2 then (
            let step = if t.never_saturated then 2. else 1. +. gain in
            t.never_saturated <- false;
            let est = r /. Float.sqrt step in
            let est = if a > 0. then Float.min est (2. *. a) else est in
            let c = Float.max a est in
            t.capacity <- Some c;
            enter t Steady ~now;
            h *. c)
          else if q <= target /. 2. && limited then
            r *. if t.never_saturated then 2. else 1. +. gain
          else r
      | Steady ->
          if q <= target then t.settled <- true
          else if t.settled && t.over_target >= 2 && a > 0. then
            t.capacity <-
              Some (match t.capacity with Some c -> Float.min c a | None -> a);
          if now -. t.since >= probe_up_every then enter t Ramping ~now;
          if off > 0. && not limited then r else r *. (1. +. (gain *. off))
      | Backing_off ->
          if now -. t.since >= backoff_hold then enter t Ramping ~now;
          r
  in
  let ceiling =
    match (t.phase, t.capacity) with
      | Ramping, _ | _, None -> infinity
      | _, Some c -> h *. c
  in
  t.rate <- clamp t.s (Float.max (Float.min next ceiling) (r *. decrease_floor))

let rate t = t.rate
let phase t = t.phase
let capacity t = t.capacity
let queueing t = t.queueing

let limit t =
  match t.s.max_rate with
    | Some m when t.rate >= 0.999 *. m -> Configured
    | _ -> if t.capacity <> None then Measured else Estimating

let base_delay t =
  Hashtbl.fold
    (fun _ p acc ->
      Some (match acc with Some b -> Float.min b p.eff | None -> p.eff))
    t.paths None
