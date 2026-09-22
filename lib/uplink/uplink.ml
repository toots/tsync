type 'io admission = {
  acquire : bytes:int -> 'io;
  completed : bytes:int -> elapsed:float -> unit;
  abandoned : bytes:int -> unit;
  now : unit -> float;
  waiting : unit -> int;
  try_admit : bytes:int -> bool;
}

let small_body = ref 65536
let probe_timeout = ref 10.

module type LOG = sig
  val info : string -> unit
  val warn : string -> unit
  val rate : float -> string
end

module Silent = struct
  let info _ = ()
  let warn _ = ()
  let rate r = Printf.sprintf "%.0f B/s" r
end

module Make
    (Io : Io.S)
    (Clock : Clock.S with type 'a io := 'a Io.t)
    (Log : LOG) =
struct
  open Io_syntax.Make (Io)

  let unbounded =
    {
      acquire = (fun ~bytes:_ -> Io.return ());
      completed = (fun ~bytes:_ ~elapsed:_ -> ());
      abandoned = (fun ~bytes:_ -> ());
      now = Clock.now;
      waiting = (fun () -> 0);
      try_admit = (fun ~bytes:_ -> true);
    }

  (* What a line asks of what is beneath it: a store's own budget, or the
     process's controller. The same line serves both. *)
  type beneath = {
    admits : now:float -> bytes:int -> bool;
    take : now:float -> bytes:int -> unit;
    wait_for : now:float -> bytes:int -> float;
    left : now:float -> bytes:int -> answered:bool -> elapsed:float -> unit;
  }

  (* A line behind a budget. [armed] is whether a timer is already set for
     the head: one at a time, since a completion may make room sooner and
     pumps then. *)
  type gate = {
    beneath : beneath;
    waiters : (int * unit Io.u) Queue.t;
    mutable armed : bool;
    mutable held_back : bool;
        (** A body waited or was refused since this was last read: the rate
            held the sender back, which is what lets it grow. *)
  }

  let gate beneath =
    { beneath; waiters = Queue.create (); armed = false; held_back = false }

  let held_back g =
    let was = g.held_back in
    g.held_back <- false;
    was

  (* Wake, in order, every waiter from the head the budget now admits. *)
  let rec pump g =
    match Queue.peek_opt g.waiters with
      | Some (bytes, wake)
        when g.beneath.admits ~now:(Clock.now ()) ~bytes ->
          ignore (Queue.pop g.waiters);
          g.beneath.take ~now:(Clock.now ()) ~bytes;
          Io.wakeup_later wake ();
          pump g
      | _ -> ()

  (* Set for the moment the head could next pass on refill alone. A head only a
     completion can free sets nothing: that completion will pump. *)
  let rec arm g =
    if not g.armed then
      match Queue.peek_opt g.waiters with
        | None -> ()
        | Some (bytes, _) ->
            let wait = g.beneath.wait_for ~now:(Clock.now ()) ~bytes in
            if wait < infinity then begin
              g.armed <- true;
              Io.async (fun () ->
                  let+ () = Clock.sleep (Float.max wait 0.001) in
                  g.armed <- false;
                  pump g;
                  arm g)
            end

  (* Room now, with nothing ahead that should go first. *)
  let room g ~bytes =
    (Queue.is_empty g.waiters || bytes <= !small_body)
    && g.beneath.admits ~now:(Clock.now ()) ~bytes

  (* Synchronous when there is room: no bind before the check, so a caller that
     asks and sends in one turn cannot have the room taken between. *)
  let acquire g ~bytes =
    if room g ~bytes then begin
      g.beneath.take ~now:(Clock.now ()) ~bytes;
      Io.return ()
    end
    else begin
      g.held_back <- true;
      let waited, wake = Io.wait () in
      Queue.add (bytes, wake) g.waiters;
      arm g;
      waited
    end

  let left g ~bytes ~answered ~elapsed =
    g.beneath.left ~now:(Clock.now ()) ~bytes ~answered ~elapsed;
    pump g;
    arm g

  let admission_of g =
    {
      acquire = acquire g;
      completed = (fun ~bytes ~elapsed -> left g ~bytes ~answered:true ~elapsed);
      abandoned = (fun ~bytes -> left g ~bytes ~answered:false ~elapsed:0.);
      now = Clock.now;
      waiting = (fun () -> Queue.length g.waiters);
      try_admit = (fun ~bytes -> room g ~bytes);
    }

  (* One after the other: the first asked first, so a store's own ceiling is
     paid before the governor's line is joined, and what the governor counts
     in flight is what is on the link and nothing waiting on a cap. *)
  let compose first second =
    {
      acquire =
        (fun ~bytes ->
          let* () = first.acquire ~bytes in
          second.acquire ~bytes);
      completed =
        (fun ~bytes ~elapsed ->
          first.completed ~bytes ~elapsed;
          second.completed ~bytes ~elapsed);
      abandoned =
        (fun ~bytes ->
          first.abandoned ~bytes;
          second.abandoned ~bytes);
      now = first.now;
      waiting = (fun () -> first.waiting () + second.waiting ());
      try_admit = (fun ~bytes -> first.try_admit ~bytes && second.try_admit ~bytes);
    }

  let capped ~rate =
    let b = Uplink_budget.create ~now:(Clock.now ()) ~rate in
    admission_of
      (gate
         {
           admits = Uplink_budget.admits b;
           take = Uplink_budget.take b;
           wait_for = Uplink_budget.wait_for b;
           left =
             (fun ~now:_ ~bytes ~answered:_ ~elapsed:_ ->
               Uplink_budget.release b ~bytes);
         })

  (* {1 The process governor} *)

  type class_ = Background | Foreground
  type mode = Owner | Leased | Local

  let string_of_mode = function
    | Owner -> "owner"
    | Leased -> "leased"
    | Local -> "local"

  (* A store on the link: whether to leave it alone, how many of its
     requests have timed out, and one small round trip to time. *)
  type probe = {
    name : string;
    held : unit -> bool;
    timeouts : unit -> int;
    probe : unit -> unit Io.t;
  }

  type t = {
    control : Uplink_control.t;
    share : Uplink_budget.t;
        (** What this process admits against: the law's rate, its own share
            of it as an owner, or the grant it holds as a lessee. *)
    line : gate;
    mutable mode : mode;
    mutable lessees : Uplink_lease.t option;  (** An owner's table. *)
    mutable daemon : (string -> string Io.t) option;
        (** A line to the owner's socket, for a lessee or one that could be. *)
    mutable missed : int;  (** Renewals unanswered in a row. *)
    mutable retry_at : float;  (** When a local process next asks the daemon. *)
    mutable interval : float;  (** What the owner said to renew at. *)
    completed_since : int ref;  (** Own bytes answered since last told. *)
    mutable probes : probe list;
    mutable ticking : bool;
    mutable last_timeouts : int;
    mutable last_state : Uplink_control.state;
    mutable probe_warned : bool;
  }

  (* A local process asks the daemon again this often; the daemon may have
     been restarted on a build that answers. *)
  let retry_every = 30.

  (* Unanswered renewals in a row before a lessee runs its own law. *)
  let missed_before_local = 3

  let create ?settings () =
    let now = Clock.now () in
    let control = Uplink_control.create ?settings ~now () in
    let share =
      Uplink_budget.create ~now ~rate:(Uplink_control.rate control)
    in
    let completed_since = ref 0 in
    let line =
      gate
        {
          admits = Uplink_budget.admits share;
          take = Uplink_budget.take share;
          wait_for = Uplink_budget.wait_for share;
          left =
            (fun ~now ~bytes ~answered ~elapsed ->
              Uplink_budget.release share ~bytes;
              if answered then begin
                completed_since := !completed_since + bytes;
                Uplink_control.completed control ~now ~bytes ~elapsed
              end);
        }
    in
    {
      control;
      share;
      line;
      mode = Local;
      lessees = None;
      daemon = None;
      missed = 0;
      retry_at = 0.;
      interval = !Uplink_control.tick_interval;
      completed_since;
      probes = [];
      ticking = false;
      last_timeouts = 0;
      last_state = Uplink_control.state control;
      probe_warned = false;
    }

  let enabled t = (Uplink_control.settings t.control).Uplink_control.enabled
  let control t = t.control
  let mode t = t.mode
  let waiting t = Queue.length t.line.waiters
  let per_sec = Log.rate

  (* What this process says of itself when it renews, or files as the owner's
     own row: what is in flight and waiting now, what completed and timed out
     since it last said. *)
  let own_report t ~timeouts =
    let r =
      {
        Uplink_lease.in_flight = Uplink_budget.in_flight_bytes t.share;
        completed = !(t.completed_since);
        timeouts;
        waiting = waiting t;
        held_back = held_back t.line;
      }
    in
    t.completed_since := 0;
    r

  (* Summed over the stores on this link, so a timeout on another link is
     not read as this one's. *)
  let timeouts_since t =
    let n = List.fold_left (fun acc p -> acc + p.timeouts ()) 0 t.probes in
    let delta = n - t.last_timeouts in
    t.last_timeouts <- n;
    delta

  (* One small round trip to every store not held down, timed on this clock,
     while anyone the law answers for has bytes in flight. A probe that times
     out is read as the timeout's length: an enormous delay, which the next
     step cuts hard on. It does not touch the store's health, which its own
     retry loop keeps. *)
  let probe_round t ~lessees_in_flight =
    let in_flight = Uplink_budget.in_flight_bytes t.share + lessees_in_flight in
    if in_flight = 0 then Io.return ()
    else
      Io.iter_p
        (fun p ->
          let started = Clock.now () in
          Io.catch
            (fun () ->
              let+ () = Clock.with_timeout !probe_timeout p.probe in
              Uplink_control.observe_delay t.control ~now:(Clock.now ())
                (Clock.now () -. started))
            (fun exn ->
              if Clock.is_timeout exn then begin
                if not t.probe_warned then begin
                  t.probe_warned <- true;
                  Log.warn
                    (Printf.sprintf
                       "uplink: a probe of %s went unanswered for %.0fs" p.name
                       !probe_timeout)
                end;
                Uplink_control.observe_delay t.control ~now:(Clock.now ())
                  !probe_timeout
              end;
              Io.return ()))
        (List.filter (fun p -> not (p.held ())) t.probes)

  let announce t =
    let state = Uplink_control.state t.control in
    if state <> t.last_state then begin
      t.last_state <- state;
      let rate = per_sec (Uplink_control.rate t.control) in
      match state with
        | Uplink_control.Steady ->
            Log.info
              (Printf.sprintf "uplink: steady at %s (capacity %s, delay +%.0f ms)"
                 rate
                 (match Uplink_control.capacity t.control with
                   | Some c -> per_sec c
                   | None -> "unknown")
                 (1000. *. Uplink_control.queueing_delay t.control))
        | Backing_off ->
            Log.info
              (Printf.sprintf "uplink: backing off to %s after a timeout" rate)
        | Ramping -> Log.info (Printf.sprintf "uplink: probing above %s" rate)
    end

  (* {2 The owner's step, and a local process's}

     Timeouts are read off the process counter the retry loops keep and off
     what lessees reported, one cut a step however many there were: no hook
     into the drivers. The law's rate is then split, the owner's own share
     being what its line admits against. *)
  let step t =
    let now = Clock.now () in
    let own_timeouts = timeouts_since t in
    let lessee_completed, lessee_timeouts =
      match t.lessees with Some l -> Uplink_lease.drain l | None -> (0, 0)
    in
    if own_timeouts + lessee_timeouts > 0 then
      Uplink_control.timed_out t.control ~now;
    (* What lessees moved is spread over the interval they reported it for. *)
    if lessee_completed > 0 then
      Uplink_control.completed t.control ~now ~bytes:lessee_completed
        ~elapsed:!Uplink_control.tick_interval;
    (* One listing a step: what is probed for, what is held back, and what
       is split are the same lessees. *)
    let lessees =
      match t.lessees with Some l -> Uplink_lease.live l ~now | None -> []
    in
    let* () =
      probe_round t
        ~lessees_in_flight:
          (List.fold_left
             (fun acc (_, (r : Uplink_lease.report)) -> acc + r.in_flight)
             0 lessees)
    in
    let now = Clock.now () in
    (* One report a step, read once: what this process is to the split, and
       what it says of itself should it ask the daemon back in this step. *)
    let mine = own_report t ~timeouts:own_timeouts in
    let limited =
      Uplink_lease.wants mine
      || List.exists (fun (_, r) -> Uplink_lease.wants r) lessees
    in
    Uplink_control.tick t.control ~now ~limited;
    let total = Uplink_control.rate t.control in
    (match t.lessees with
      | Some l ->
          let min_rate =
            float_of_int (Uplink_control.settings t.control).min_rate
          in
          Uplink_lease.split l ~now ~total ~min_rate ~self:mine;
          Uplink_budget.set_rate t.share ~now (Uplink_lease.own_rate l)
      | None -> Uplink_budget.set_rate t.share ~now total);
    announce t;
    pump t.line;
    arm t.line;
    Io.return mine

  (* {2 A lessee's renewal} *)

  let request (r : Uplink_lease.report) =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("action", `String "uplink");
          ("pid", `Int (Unix.getpid ()));
          ("inFlight", `Int r.Uplink_lease.in_flight);
          ("completed", `Int r.completed);
          ("timeouts", `Int r.timeouts);
          ("waiting", `Int r.waiting);
          ("heldBack", `Bool r.held_back);
        ])

  type answer = Granted of float * float | Refused | Unreached

  let read_answer line =
    match Yojson.Safe.from_string line with
      | `Assoc fields -> (
          let num key =
            match List.assoc_opt key fields with
              | Some (`Int n) -> Some (float_of_int n)
              | Some (`Float f) -> Some f
              | _ -> None
          in
          match (List.assoc_opt "ok" fields, num "rate") with
            | Some (`Bool true), Some rate ->
                Granted
                  ( rate,
                    Option.value (num "interval")
                      ~default:!Uplink_control.tick_interval )
            | _ -> Refused)
      | _ | (exception _) -> Refused

  let fall_to_local t why =
    t.mode <- Local;
    t.retry_at <- Clock.now () +. retry_every;
    Log.warn
      (Printf.sprintf "uplink: %s; governing this process's link alone" why)

  (* One renewal: what came back sets the grant, and what did not counts.
     [Refused] is a daemon that does not know the action, which no retry will
     change soon; [Unreached] is one that may be back. *)
  (* [report] is what this process says of itself: a step that has just read
     it hands it on, so a busy process asking the daemon back does not report
     itself idle. *)
  let renew t ~send ~report =
    let* answer =
      Io.catch
        (fun () ->
          let+ line = send (request report) in
          read_answer line)
        (fun _ -> Io.return Unreached)
    in
    (match answer with
      | Granted (rate, interval) ->
          t.missed <- 0;
          t.interval <- interval;
          Uplink_budget.set_rate t.share ~now:(Clock.now ()) rate;
          if t.mode <> Leased then begin
            t.mode <- Leased;
            Log.info
              (Printf.sprintf "uplink: leasing %s from the daemon" (per_sec rate))
          end
      | Refused ->
          if t.mode = Leased then
            fall_to_local t "the daemon does not answer for the link"
      | Unreached ->
          t.missed <- t.missed + 1;
          if t.mode = Leased && t.missed >= missed_before_local then
            fall_to_local t
              (Printf.sprintf "%d renewals unanswered" missed_before_local));
    pump t.line;
    arm t.line;
    Io.return ()

  (* A local process with a daemon to ask asks it again now and then. *)
  let maybe_retry t ~report =
    match (t.mode, t.daemon) with
      | Local, Some send when Clock.now () >= t.retry_at ->
          t.retry_at <- Clock.now () +. retry_every;
          renew t ~send ~report
      | _ -> Io.return ()

  (* One loop whatever the mode: a lessee renews at the owner's interval,
     everyone else steps the law at its own. *)
  let rec ticker t =
    let* () =
      Clock.sleep
        (match t.mode with
          | Leased -> t.interval
          | Owner | Local -> !Uplink_control.tick_interval)
    in
    let* () =
      match (t.mode, t.daemon) with
        | Leased, Some send ->
            renew t ~send ~report:(own_report t ~timeouts:(timeouts_since t))
        | Leased, None -> fall_to_local t "no daemon to renew from"; Io.return ()
        | (Owner | Local), _ ->
            let* report = step t in
            maybe_retry t ~report
    in
    ticker t

  let ensure_ticking t =
    if enabled t && not t.ticking then begin
      t.ticking <- true;
      Io.async (fun () -> ticker t)
    end

  (* {2 Deciding what this process is} *)

  (* Split at once, so a lessee renewing before the first step is granted an
     even share of the law's starting rate rather than nothing. *)
  let own t =
    t.mode <- Owner;
    t.daemon <- None;
    (match t.lessees with
      | Some _ -> ()
      | None ->
          let l = Uplink_lease.create () in
          Uplink_lease.split l ~now:(Clock.now ())
            ~total:(Uplink_control.rate t.control)
            ~min_rate:
              (float_of_int (Uplink_control.settings t.control).min_rate)
            ~self:Uplink_lease.idle;
          t.lessees <- Some l);
    ensure_ticking t

  let lease_through t ~send =
    if t.mode <> Owner then begin
      t.daemon <- Some send;
      t.mode <- Leased;
      t.missed <- 0
    end

  let lease_renewal t ~pid report =
    match (t.mode, t.lessees) with
      | Owner, Some l ->
          let now = Clock.now () in
          Uplink_lease.record l ~now ~pid report;
          Some (Uplink_lease.rate_for l ~now ~pid, t.interval)
      | _ -> None

  let acquire t ~class_ ~bytes =
    if not (enabled t) then Io.return ()
    else
      match class_ with
        | Foreground -> Io.return ()
        | Background ->
            ensure_ticking t;
            acquire t.line ~bytes

  let try_admit t ~bytes =
    if not (enabled t) then true
    else begin
      ensure_ticking t;
      if room t.line ~bytes then true
      else begin
        t.line.held_back <- true;
        Uplink_control.dropped t.control;
        false
      end
    end

  let admission t class_ =
    {
      (admission_of t.line) with
      acquire = (fun ~bytes -> acquire t ~class_ ~bytes);
      try_admit =
        (fun ~bytes ->
          match class_ with
            | Foreground -> true
            | Background -> try_admit t ~bytes);
    }

  (* What the store has timed out so far is not this link's to cut on. *)
  let attach t ~name ~held ~timeouts ~probe =
    t.last_timeouts <- t.last_timeouts + timeouts ();
    t.probes <- { name; held; timeouts; probe } :: t.probes;
    ensure_ticking t

  (* The budget's figures sit where a reader expects them, beside the drops,
     whichever module happens to hold them. A lessee runs no law, so it
     says so in place of a state and a capacity it does not have. *)
  let json t =
    let now = Clock.now () in
    List.concat_map
      (fun (k, v) ->
        match (k, t.mode) with
          | "state", Leased -> [(k, `String "leased")]
          | "capacityBytesPerSec", Leased -> [(k, `Null)]
          | "rateBytesPerSec", Leased ->
              [(k, `Int (int_of_float (Uplink_budget.rate t.share)))]
          | "drops", _ ->
              [
                ("inFlightBytes", `Int (Uplink_budget.in_flight_bytes t.share));
                ("windowBytes", `Int (Uplink_budget.window_bytes t.share));
                (k, v);
              ]
          | _ -> [(k, v)])
      (Uplink_control.json t.control ~now)
    @ [("waiting", `Int (waiting t)); ("mode", `String (string_of_mode t.mode))]
    @
    match t.lessees with
      | Some l when t.mode = Owner ->
          [
            ("ownRateBytesPerSec", `Int (int_of_float (Uplink_budget.rate t.share)));
            ("lessees", `List (Uplink_lease.json l ~now));
          ]
      | _ -> []

  let the_process : t option ref = ref None

  let configure settings =
    match !the_process with
      | Some _ -> ()
      | None -> the_process := Some (create ~settings ())

  let process () =
    match !the_process with
      | Some t -> t
      | None ->
          let t = create () in
          the_process := Some t;
          t
end
