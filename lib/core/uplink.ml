type 'io admission = {
  acquire : bytes:int -> 'io;
  completed : bytes:int -> elapsed:float -> unit;
  abandoned : bytes:int -> unit;
  now : unit -> float;
  waiting : unit -> int;
}

let small_body = ref 65536

module Make (Io : Io.S) (Clock : Clock.S with type 'a io := 'a Io.t) = struct
  open Io_syntax.Make (Io)

  let unbounded =
    {
      acquire = (fun ~bytes:_ -> Io.return ());
      completed = (fun ~bytes:_ ~elapsed:_ -> ());
      abandoned = (fun ~bytes:_ -> ());
      now = Clock.now;
      waiting = (fun () -> 0);
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
  }

  let gate beneath = { beneath; waiters = Queue.create (); armed = false }

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

  type probe = { name : string; held : unit -> bool; probe : unit -> unit Io.t }

  type t = {
    control : Uplink_control.t;
    line : gate;
    mutable probes : probe list;
    mutable ticking : bool;
    mutable last_timeouts : int;
    mutable last_state : Uplink_control.state;
    mutable probe_warned : bool;
  }

  let create ?settings () =
    let control = Uplink_control.create ?settings ~now:(Clock.now ()) () in
    {
      control;
      line =
        gate
          {
            admits = Uplink_control.admits control;
            take = Uplink_control.take control;
            wait_for = Uplink_control.wait_for control;
            left =
              (fun ~now ~bytes ~answered ~elapsed ->
                if answered then
                  Uplink_control.completed control ~now ~bytes ~elapsed
                else Uplink_control.abandoned control ~now ~bytes);
          };
      probes = [];
      ticking = false;
      last_timeouts = Metrics.timeouts ();
      last_state = Uplink_control.state control;
      probe_warned = false;
    }

  let enabled t = (Uplink_control.settings t.control).Uplink_control.enabled
  let control t = t.control
  let waiting t = Queue.length t.line.waiters

  (* One small round trip to every store not held down, timed on this clock.
     A probe that times out is read as the timeout's length: an enormous
     delay, which the next step cuts hard on. It does not touch the store's
     health, which its own retry loop keeps. *)
  let probe_round t =
    if Uplink_control.in_flight_bytes t.control = 0 then Io.return ()
    else
      Io.iter_p
        (fun p ->
          let started = Clock.now () in
          Io.catch
            (fun () ->
              let+ () = Clock.with_timeout !Health.probe_timeout p.probe in
              Uplink_control.observe_delay t.control ~now:(Clock.now ())
                (Clock.now () -. started))
            (fun exn ->
              if Clock.is_timeout exn then begin
                if not t.probe_warned then begin
                  t.probe_warned <- true;
                  Log.warn "uplink: a probe of %s went unanswered for %.0fs"
                    p.name !Health.probe_timeout
                end;
                Uplink_control.observe_delay t.control ~now:(Clock.now ())
                  !Health.probe_timeout
              end;
              Io.return ()))
        (List.filter (fun p -> not (p.held ())) t.probes)

  let per_sec rate = Metrics.human_bytes (int_of_float rate) ^ "/s"

  let announce t =
    let state = Uplink_control.state t.control in
    if state <> t.last_state then begin
      t.last_state <- state;
      let rate = per_sec (Uplink_control.rate t.control) in
      match state with
        | Uplink_control.Steady ->
            Log.info "uplink: steady at %s (capacity %s, delay +%.0f ms)" rate
              (match Uplink_control.capacity t.control with
                | Some c -> per_sec c
                | None -> "unknown")
              (1000. *. Uplink_control.queueing_delay t.control)
        | Backing_off -> Log.info "uplink: backing off to %s after a timeout" rate
        | Ramping -> Log.info "uplink: probing above %s" rate
    end

  (* Timeouts are read off the process counter the retry loops keep, one cut a
     step however many there were: no hook into the drivers. *)
  let step t =
    let timeouts = Metrics.timeouts () in
    if timeouts > t.last_timeouts then
      Uplink_control.timed_out t.control ~now:(Clock.now ());
    t.last_timeouts <- timeouts;
    let* () = probe_round t in
    Uplink_control.tick t.control ~now:(Clock.now ());
    announce t;
    pump t.line;
    arm t.line;
    Io.return ()

  let rec ticker t =
    let* () = Clock.sleep !Uplink_control.tick_interval in
    let* () = step t in
    ticker t

  let ensure_ticking t =
    if enabled t && not t.ticking then begin
      t.ticking <- true;
      Io.async (fun () -> ticker t)
    end

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
        Uplink_control.dropped t.control;
        false
      end
    end

  let admission t class_ =
    {
      (admission_of t.line) with
      acquire = (fun ~bytes -> acquire t ~class_ ~bytes);
    }

  let attach t ~name ~held ~probe =
    t.probes <- { name; held; probe } :: t.probes;
    ensure_ticking t

  let json t =
    Uplink_control.json t.control ~now:(Clock.now ())
    @ [("waiting", `Int (waiting t))]

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
