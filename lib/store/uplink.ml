open Tsync_core
module Law = Uplink_law
module Lease = Uplink_lease

let burst_seconds = 2.
let stall_timeout = 60.
let window_safety = 0.5
let small_body = 64 * 1024
let request_overhead = 1024
let missed_before_local = 3
let renewal_timeout = 1.
let local_retry = 30.
let state_save_interval = 60.

module Budget = struct
  type t = {
    mutable rate : float;
    mutable tokens : float;
    mutable filled_at : float;
    mutable in_flight : int;
  }

  let burst t = t.rate *. burst_seconds
  let window t = t.rate *. stall_timeout *. window_safety

  let create ~rate ~now =
    let rate = Float.max 1. rate in
    { rate; tokens = rate *. burst_seconds; filled_at = now; in_flight = 0 }

  let refill t ~now =
    if now > t.filled_at then (
      t.tokens <-
        Float.min (burst t) (t.tokens +. (t.rate *. (now -. t.filled_at)));
      t.filled_at <- now)

  (* A body larger than the bucket needs only a full one; the excess is debt. *)
  let asks t b = Float.min (float_of_int b) (burst t)

  let window_admits t b =
    t.in_flight = 0 || float_of_int (t.in_flight + b) <= window t

  let admits t ~now b =
    refill t ~now;
    t.tokens >= asks t b && window_admits t b

  let take t ~now b =
    refill t ~now;
    t.tokens <- t.tokens -. float_of_int b;
    t.in_flight <- t.in_flight + b

  let release t b = t.in_flight <- max 0 (t.in_flight - b)

  let wait_for t ~now b =
    refill t ~now;
    if not (window_admits t b) then infinity
    else Float.max 0. ((asks t b -. t.tokens) /. t.rate)

  let set_rate t ~now r =
    refill t ~now;
    t.rate <- Float.max 1. r;
    t.tokens <- Float.min t.tokens (burst t)

  let rate t = t.rate
  let in_flight t = t.in_flight
  let window_bytes t = window t
end

type settings = { enabled : bool; law : Law.settings }
type waiter = { bytes : int; wake : (unit, exn) result Rt.Promise.t }
type probe = { store : string; run : unit -> unit; health : Health.t }

type lessee = {
  mutable report : Lease.report;
  mutable seen : float;
  mutable grant : float;
}

type gate = {
  name : string;
  settings : Law.settings;
  m : Mutex.t;
  budget : Budget.t;
  line : waiter Queue.t;
  mutable overtaken : int;
  mutable armed : bool;
  mutable law : Law.t;
  mutable used : bool;
  mutable held_back : bool;
  mutable drops : int;
  mutable completed_since : float;
  mutable probes : probe list;
  mutable last_timeouts : int;
  lessees : (int, lessee) Hashtbl.t;
  mutable lessee_completed : float;
  mutable lessee_timeouts : int;
  mutable own_grant : float;
}

type t = Open | Governed of gate
type ticket = { taken : int; at : float }
type mode = Owner | Leased | Local

(* Process-wide governor state (§3), guarded by [proc_m]. *)
type proc = {
  mutable mode : mode;
  mutable missed : int;
  mutable retry_at : float;
  mutable interval : float;
  mutable renew : (Yojson.Safe.t -> Yojson.Safe.t) option;
  mutable state_file : string option;
  mutable saved : (string * (float * float)) list;
  mutable saved_at : float;
  mutable ticking : bool;
  mutable settings_for : (string -> settings) option;  (** set by {!own} *)
}

let proc =
  {
    mode = Local;
    missed = 0;
    retry_at = 0.;
    interval = Law.tick_interval;
    renew = None;
    state_file = None;
    saved = [];
    saved_at = 0.;
    ticking = false;
    settings_for = None;
  }

let proc_m = Mutex.create ()
let none = Open
let links : (string, t) Hashtbl.t = Hashtbl.create 4
let links_m = Mutex.create ()

let governed () =
  Mutex.protect links_m (fun () ->
      Hashtbl.fold
        (fun _ t acc -> match t with Governed g -> g :: acc | Open -> acc)
        links [])

let new_law name settings ~now =
  match List.assoc_opt name proc.saved with
    | Some (capacity, saved_at) ->
        Law.restore settings ~now ~capacity
          ~saved_at:(Rt.now () -. (Unix.gettimeofday () -. saved_at))
    | None -> Law.create settings ~now

let create_gate name settings =
  let now = Rt.now () in
  let law = Mutex.protect proc_m (fun () -> new_law name settings ~now) in
  {
    name;
    settings;
    m = Mutex.create ();
    budget = Budget.create ~rate:(Law.rate law) ~now;
    line = Queue.create ();
    overtaken = 0;
    armed = false;
    law;
    used = false;
    held_back = false;
    drops = 0;
    completed_since = 0.;
    probes = [];
    last_timeouts = 0;
    lessees = Hashtbl.create 4;
    lessee_completed = 0.;
    lessee_timeouts = 0;
    own_grant = Law.rate law;
  }

let link name s =
  Mutex.protect links_m (fun () ->
      match Hashtbl.find_opt links name with
        | Some t -> t
        | None ->
            let t =
              if s.enabled then Governed (create_gate name s.law) else Open
            in
            Hashtbl.replace links name t;
            t)

(* Called under [g.m]. *)
let rec pump g =
  match Queue.peek_opt g.line with
    | Some w when Budget.admits g.budget ~now:(Rt.now ()) w.bytes ->
        ignore (Queue.pop g.line);
        g.overtaken <- 0;
        if Rt.Promise.try_resolve w.wake (Ok ()) then
          Budget.take g.budget ~now:(Rt.now ()) w.bytes;
        pump g
    | _ -> ()

(* One timer at most; a head blocked by the window waits for a completion. *)
and arm g =
  if not g.armed then (
    match Queue.peek_opt g.line with
      | Some w ->
          let delay = Budget.wait_for g.budget ~now:(Rt.now ()) w.bytes in
          if delay < infinity then (
            g.armed <- true;
            Rt.timer (Float.max 0.001 delay) (fun () ->
                Mutex.protect g.m (fun () ->
                    g.armed <- false;
                    pump g;
                    arm g)))
      | None -> ())

(* §4.3: a small body may pass the head, by at most the head's size in all. *)
let room g b =
  (match Queue.peek_opt g.line with
    | None -> true
    | Some head -> b <= small_body && g.overtaken + b <= head.bytes)
  && Budget.admits g.budget ~now:(Rt.now ()) b

let take_now g b =
  if not (Queue.is_empty g.line) then g.overtaken <- g.overtaken + b;
  Budget.take g.budget ~now:(Rt.now ()) b

let limit_name g =
  match Law.limit g.law with
    | Law.Configured -> "configured"
    | Measured -> "measured"
    | Estimating -> "estimating"

let own_report g ~timeouts ~probes =
  let r =
    {
      Lease.in_flight = Budget.in_flight g.budget;
      completed = g.completed_since;
      timeouts;
      waiting = Queue.length g.line;
      held_back = g.held_back;
      probes;
    }
  in
  g.completed_since <- 0.;
  g.held_back <- false;
  r

(* §4.5, under [g.m]. *)
let split g ~mine =
  let rows = Hashtbl.fold (fun pid l acc -> (pid, l) :: acc) g.lessees [] in
  let rows = List.sort compare rows in
  match
    Lease.split ~total:(Law.rate g.law) ~min_rate:g.settings.min_rate
      ~interval:Law.tick_interval
      (mine :: List.map (fun (_, l) -> l.report) rows)
  with
    | own :: grants ->
        List.iter2
          (fun (_, l) grant ->
            l.grant <- grant;
            l.report <- { l.report with held_back = false })
          rows grants;
        g.own_grant <- own;
        Budget.set_rate g.budget ~now:(Rt.now ()) own
    | [] -> ()

let dormant g = (not g.used) && g.probes = [] && Hashtbl.length g.lessees = 0
let lease_ttl () = (3. *. proc.interval) +. Law.probe_timeout

(* Under [g.m]: the probes' timeouts since the last read. *)
let timeouts_since g =
  let total =
    List.fold_left (fun acc p -> acc + Health.timeouts p.health) 0 g.probes
  in
  let fresh = total - g.last_timeouts in
  g.last_timeouts <- total;
  max 0 fresh

(* An unanswered probe reads as PROBE_TIMEOUT; other failures drop the sample. *)
let probe_round g =
  let probes =
    Mutex.protect g.m (fun () ->
        List.filter (fun p -> not (Health.is_held p.health)) g.probes)
  in
  List.filter_map Fun.id
    (Rt.map_concurrently
       (fun p ->
         let t0 = Rt.now () in
         match Rt.with_timeout Law.probe_timeout p.run with
           | () -> Some (p.store, Rt.now () -. t0)
           | exception Rt.Timeout -> Some (p.store, Law.probe_timeout)
           | exception e when not (Rt.is_cancelled e) -> None)
       probes)

let pump_and_arm g =
  Mutex.protect g.m (fun () ->
      pump g;
      arm g)

(* §4.6: one step of an Owner or Local process, answering its own report. *)
let step g ~owner =
  let now = Rt.now () in
  let own_timeouts, busy =
    Mutex.protect g.m (fun () ->
        let own_timeouts = timeouts_since g in
        let lc = g.lessee_completed and lt = g.lessee_timeouts in
        g.lessee_completed <- 0.;
        g.lessee_timeouts <- 0;
        Hashtbl.filter_map_inplace
          (fun pid l ->
            if Fs.pid_alive pid && now -. l.seen <= lease_ttl () then Some l
            else None)
          g.lessees;
        if own_timeouts + lt > 0 then Law.timed_out g.law ~now;
        if lc > 0. then Law.completed g.law ~now lc ~elapsed:Law.tick_interval;
        let busy =
          Budget.in_flight g.budget > 0
          || Hashtbl.fold
               (fun _ l b -> b || l.report.in_flight > 0)
               g.lessees false
        in
        (own_timeouts, busy))
  in
  let samples = if busy then probe_round g else [] in
  Mutex.protect g.m (fun () ->
      List.iter (fun (s, d) -> Law.observe_delay g.law s d) samples;
      let mine = own_report g ~timeouts:own_timeouts ~probes:samples in
      let limited =
        Lease.wants mine
        || Hashtbl.fold (fun _ l b -> b || Lease.wants l.report) g.lessees false
      in
      Law.tick g.law ~now:(Rt.now ()) ~limited ~busy;
      if owner then split g ~mine
      else Budget.set_rate g.budget ~now:(Rt.now ()) (Law.rate g.law);
      pump g;
      arm g;
      mine)

(* A Leased tick probes only while its own bytes are in flight. *)
let lessee_report g =
  let timeouts, busy =
    Mutex.protect g.m (fun () ->
        (timeouts_since g, Budget.in_flight g.budget > 0))
  in
  let samples = if busy then probe_round g else [] in
  Mutex.protect g.m (fun () -> own_report g ~timeouts ~probes:samples)

let set_mode m =
  Mutex.protect proc_m (fun () ->
      if proc.mode <> m then
        Log.info "uplink: %s"
          (match m with
            | Owner -> "owner"
            | Leased -> "leased"
            | Local -> "local");
      proc.mode <- m;
      if m = Local then proc.retry_at <- Rt.now () +. local_retry)

(* §4.5: Granted, Refused or Unreached; every link is pumped in any case. *)
let renew gates reports =
  match proc.renew with
    | None -> set_mode Local
    | Some call ->
        let request = Lease.request_to_json ~pid:(Unix.getpid ()) reports in
        (match Rt.with_timeout renewal_timeout (fun () -> call request) with
          | answer -> (
              match Lease.answer_of_json answer with
                | Some (interval, grants) ->
                    Mutex.protect proc_m (fun () ->
                        proc.missed <- 0;
                        proc.interval <- interval);
                    set_mode Leased;
                    List.iter
                      (fun g ->
                        match List.assoc_opt g.name grants with
                          | Some r ->
                              Mutex.protect g.m (fun () ->
                                  Budget.set_rate g.budget ~now:(Rt.now ()) r)
                          | None -> ())
                      gates
                | None -> set_mode Local)
          | exception e when not (Rt.is_cancelled e) ->
              let missed =
                Mutex.protect proc_m (fun () ->
                    proc.missed <- proc.missed + 1;
                    proc.missed)
              in
              if missed >= missed_before_local then set_mode Local);
        List.iter pump_and_arm gates

let save_state () =
  match proc.state_file with
    | None -> ()
    | Some path ->
        let entries =
          List.filter_map
            (fun g ->
              Mutex.protect g.m (fun () ->
                  Option.map
                    (fun c ->
                      ( g.name,
                        `Assoc
                          [
                            ("capacity", `Float c);
                            ("rate", `Float (Law.rate g.law));
                            ("savedAt", `Float (Unix.gettimeofday ()));
                          ] ))
                    (Law.capacity g.law)))
            (governed ())
        in
        (try Fs.replace path (Yojson.Safe.to_string (`Assoc entries))
         with e ->
           Log.warn "uplink: cannot save %s: %s" path (Printexc.to_string e));
        proc.saved_at <- Rt.now ()

let step_all () =
  let gates =
    List.filter
      (fun g -> not (Mutex.protect g.m (fun () -> dormant g)))
      (governed ())
  in
  match Mutex.protect proc_m (fun () -> proc.mode) with
    | Leased ->
        renew gates (List.map (fun g -> (g.name, lessee_report g)) gates)
    | Owner ->
        List.iter (fun g -> ignore (step g ~owner:true)) gates;
        if Rt.now () -. proc.saved_at >= state_save_interval then save_state ()
    | Local ->
        let reports = List.map (fun g -> (g.name, step g ~owner:false)) gates in
        if proc.renew <> None && Rt.now () >= proc.retry_at then (
          Mutex.protect proc_m (fun () ->
              proc.retry_at <- Rt.now () +. local_retry);
          renew gates reports)

let rec ticker () =
  let interval =
    Mutex.protect proc_m (fun () ->
        if proc.mode = Leased then proc.interval else Law.tick_interval)
  in
  Stop.sleep interval;
  (try step_all ()
   with e when not (Rt.is_cancelled e || e = Stop.Stopping) ->
     Log.warn "uplink step: %s" (Printexc.to_string e));
  ticker ()

let ensure_ticking () =
  let start =
    Mutex.protect proc_m (fun () ->
        let start = not proc.ticking in
        proc.ticking <- true;
        start)
  in
  if start then
    Rt.spawn ~name:"uplink" (fun () ->
        try ticker ()
        with Stop.Stopping ->
          if Mutex.protect proc_m (fun () -> proc.mode) = Owner then
            save_state ())

let read_saved path =
  match
    Yojson.Safe.from_string (Option.value ~default:"" (Fs.read_file_opt path))
  with
    | `Assoc l ->
        List.filter_map
          (fun (name, j) ->
            match j with
              | `Assoc f -> (
                  let num k =
                    match List.assoc_opt k f with
                      | Some (`Float x) -> Some x
                      | Some (`Int i) -> Some (float_of_int i)
                      | _ -> None
                  in
                  match (num "capacity", num "savedAt") with
                    | Some c, Some at -> Some (name, (c, at))
                    | _ -> None)
              | _ -> None)
          l
    | _ -> []
    | exception _ -> []

let own ?state_file settings_for =
  let saved = Option.fold ~none:[] ~some:read_saved state_file in
  Mutex.protect proc_m (fun () ->
      proc.state_file <- state_file;
      proc.saved <- saved;
      proc.saved_at <- Rt.now ();
      proc.settings_for <- Some settings_for);
  List.iter
    (fun g ->
      Mutex.protect g.m (fun () ->
          if Law.capacity g.law = None && not g.used then
            g.law <-
              Mutex.protect proc_m (fun () ->
                  new_law g.name g.settings ~now:(Rt.now ()))))
    (governed ());
  set_mode Owner;
  ensure_ticking ()

let lease call =
  Mutex.protect proc_m (fun () ->
      proc.renew <- Some call;
      proc.mode <- Leased)

let renewal json =
  match
    ( Mutex.protect proc_m (fun () -> (proc.mode, proc.settings_for)),
      Lease.request_of_json json )
  with
    | (Owner, Some settings_for), Some req ->
        let now = Rt.now () in
        let grants =
          List.filter_map
            (fun (name, (r : Lease.report)) ->
              match link name (settings_for name) with
                | Open -> None
                | Governed g ->
                    Mutex.protect g.m (fun () ->
                        List.iter
                          (fun (s, d) -> Law.observe_delay g.law s d)
                          r.probes;
                        g.lessee_completed <- g.lessee_completed +. r.completed;
                        g.lessee_timeouts <- g.lessee_timeouts + r.timeouts;
                        (match Hashtbl.find_opt g.lessees req.pid with
                          | Some l ->
                              l.report <- r;
                              l.seen <- now
                          | None ->
                              Hashtbl.replace g.lessees req.pid
                                { report = r; seen = now; grant = 0. };
                              let mine =
                                {
                                  Lease.idle with
                                  in_flight = Budget.in_flight g.budget;
                                  waiting = Queue.length g.line;
                                  held_back = g.held_back;
                                }
                              in
                              split g ~mine;
                              pump g;
                              arm g);
                        let l = Hashtbl.find g.lessees req.pid in
                        Some
                          (name, { Lease.rate = l.grant; limit = limit_name g })))
            req.links
        in
        ensure_ticking ();
        Some
          (Lease.answer_to_json ~interval:Law.tick_interval ~flat:req.flat
             grants)
    | _ -> None

let attach t ~store ~probe ~health =
  match t with
    | Open -> ()
    | Governed g ->
        Mutex.protect g.m (fun () ->
            g.last_timeouts <- g.last_timeouts + Health.timeouts health;
            g.probes <- { store; run = probe; health } :: g.probes);
        ensure_ticking ()

let used g =
  if not g.used then (
    g.used <- true;
    true)
  else false

let acquire t bytes =
  let b = bytes + request_overhead in
  match t with
    | Open -> { taken = 0; at = 0. }
    | Governed g -> (
        let first, waiter =
          Mutex.protect g.m (fun () ->
              let first = used g in
              if room g b then (
                take_now g b;
                (first, None))
              else (
                let w = { bytes = b; wake = Rt.Promise.create () } in
                g.held_back <- true;
                Queue.push w g.line;
                arm g;
                (first, Some w)))
        in
        if first then ensure_ticking ();
        match waiter with
          | None -> { taken = b; at = Rt.now () }
          | Some w ->
              let unregister =
                Stop.on_request (fun () ->
                    ignore (Rt.Promise.try_resolve w.wake (Error Stop.Stopping)))
              in
              Fun.protect ~finally:unregister (fun () ->
                  match Rt.Promise.await w.wake with
                    | Ok () -> { taken = b; at = Rt.now () }
                    | Error e -> raise e
                    | exception e ->
                        (* A waiter cancelled while in line leaves it having
                           taken nothing. *)
                        Mutex.protect g.m (fun () ->
                            if not (Rt.Promise.try_resolve w.wake (Error e))
                            then Budget.release g.budget b;
                            let kept = Queue.create () in
                            Queue.iter
                              (fun x -> if x != w then Queue.push x kept)
                              g.line;
                            Queue.clear g.line;
                            Queue.transfer kept g.line;
                            pump g;
                            arm g);
                        raise e))

let try_acquire t bytes =
  let b = bytes + request_overhead in
  match t with
    | Open -> Some { taken = 0; at = 0. }
    | Governed g ->
        let first, ticket =
          Mutex.protect g.m (fun () ->
              let first = used g in
              if room g b then (
                take_now g b;
                (first, Some { taken = b; at = Rt.now () }))
              else (
                g.held_back <- true;
                g.drops <- g.drops + 1;
                (first, None)))
        in
        if first then ensure_ticking ();
        ticket

let left t ticket ~answered =
  match t with
    | Open -> ()
    | Governed g ->
        Mutex.protect g.m (fun () ->
            Budget.release g.budget ticket.taken;
            if answered then (
              let now = Rt.now () in
              let bytes = float_of_int ticket.taken in
              g.completed_since <- g.completed_since +. bytes;
              Law.completed g.law ~now bytes ~elapsed:(now -. ticket.at));
            pump g;
            arm g)

let completed t ticket = left t ticket ~answered:true
let abandoned t ticket = left t ticket ~answered:false

let waiting = function
  | Open -> 0
  | Governed g -> Mutex.protect g.m (fun () -> Queue.length g.line)

let admitted t (mode : Store.mode) bytes f =
  let ticket =
    match mode with
      | Wait -> acquire t bytes
      | Best_effort -> (
          match try_acquire t bytes with
            | Some ticket -> ticket
            | None -> raise Rt.Cancelled)
  in
  match f () with
    | v ->
        completed t ticket;
        v
    | exception e ->
        abandoned t ticket;
        raise e

let ms s = `Float (Float.round (s *. 10000.) /. 10.)

(* §4.9 *)
let status () =
  let mode = Mutex.protect proc_m (fun () -> proc.mode) in
  let mode_name =
    match mode with Owner -> "owner" | Leased -> "leased" | Local -> "local"
  in
  let one g =
    Mutex.protect g.m (fun () ->
        let now = Rt.now () in
        let state =
          match (mode, Law.phase g.law) with
            | Leased, _ -> "leased"
            | _, Law.Ramping -> "ramping"
            | _, Steady -> "steady"
            | _, Backing_off -> "backingOff"
        in
        let opt f = function Some x -> f x | None -> `Null in
        let base =
          [
            ("enabled", `Bool true);
            ("state", `String state);
            ("limit", `String (limit_name g));
            ("maxRateBytesPerSec", opt (fun r -> `Float r) g.settings.max_rate);
            ( "rateBytesPerSec",
              `Float
                (if mode = Leased then Budget.rate g.budget else Law.rate g.law)
            );
            ("capacityBytesPerSec", opt (fun c -> `Float c) (Law.capacity g.law));
            ("achievedBytesPerSec", `Float (Law.achieved g.law ~now));
            ("baseDelayMs", opt ms (Law.base_delay g.law));
            ("queueingDelayMs", ms (Law.queueing g.law));
            ("inFlightBytes", `Int (Budget.in_flight g.budget));
            ("windowBytes", `Float (Budget.window_bytes g.budget));
            ("drops", `Int g.drops);
            ("headroom", `Float g.settings.headroom);
            ("targetDelayMs", ms g.settings.target_delay);
            ("waiting", `Int (Queue.length g.line));
            ("mode", `String mode_name);
          ]
        in
        let owner =
          if mode <> Owner then []
          else
            [
              ("ownRateBytesPerSec", `Float g.own_grant);
              ( "lessees",
                `List
                  (Hashtbl.fold
                     (fun pid l acc ->
                       `Assoc
                         [
                           ("pid", `Int pid);
                           ("rateBytesPerSec", `Float l.grant);
                           ("inFlightBytes", `Int l.report.in_flight);
                           ("waiting", `Int l.report.waiting);
                           ("heldBack", `Bool l.report.held_back);
                           ( "probeMs",
                             match l.report.probes with
                               | [] -> `Null
                               | ps ->
                                   ms
                                     (List.fold_left
                                        (fun a (_, d) -> Float.min a d)
                                        infinity ps) );
                         ]
                       :: acc)
                     g.lessees []) );
            ]
        in
        (g.name, `Assoc (base @ owner)))
  in
  `Assoc
    (List.filter_map
       (fun g ->
         if Mutex.protect g.m (fun () -> dormant g) then None else Some (one g))
       (List.sort (fun a b -> compare a.name b.name) (governed ())))
