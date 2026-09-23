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
let default_link = "wan"

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

module Make (Io : Io.S) (Clock : Clock.S with type 'a io := 'a Io.t) (Log : LOG) =
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
        (** A body waited or was refused since this was last read: the rate held
            the sender back, which is what lets it grow. *)
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
      | Some (bytes, wake) when g.beneath.admits ~now:(Clock.now ()) ~bytes ->
          ignore (Queue.pop g.waiters);
          g.beneath.take ~now:(Clock.now ()) ~bytes;
          Io.wakeup_later wake ();
          pump g
      | _ -> ()

  (* Set for the moment the head could next pass on refill alone. A head only a
     completion can free sets nothing: that completion will pump. *)
  let rec arm g =
    if not g.armed then (
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
            end)

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
      try_admit =
        (fun ~bytes -> first.try_admit ~bytes && second.try_admit ~bytes);
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

  (* {1 The process governor: one link at a time, all of them together} *)

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

  (* One link's governor, and the process it belongs to. What a process is
     to its links, and the line to the daemon, are the process's; the law, the
     budget, the line and the lessees are each link's own. *)
  type t = {
    name : string;
    proc : process;
    control : Uplink_control.t;
    share : Uplink_budget.t;
        (** What this process admits against on this link: the law's rate, its
            own share of it as an owner, or the grant it holds as a lessee. *)
    line : gate;
    mutable lessees : Uplink_lease.t option;  (** An owner's table. *)
    completed_since : int ref;  (** Own bytes answered since last told. *)
    mutable probes : probe list;
    mutable last_timeouts : int;
    mutable last_state : Uplink_control.state;
    mutable probe_warned : bool;
    mutable used : bool;  (** Something here has asked for room. *)
    mutable granted_limit : Uplink_control.limit option;
        (** A lessee's: what holds the owner's rate, as it last said. *)
  }

  and process = {
    links : (string, t) Hashtbl.t;
    mutable defaults : Uplink_control.settings;
    mutable overrides : (string * Uplink_control.settings) list;
    mutable mode : mode;
    mutable daemon : (string -> string Io.t) option;
        (** A line to the owner's socket, for a lessee or one that could be. *)
    mutable missed : int;  (** Renewals unanswered in a row. *)
    mutable retry_at : float;  (** When a local process next asks the daemon. *)
    mutable interval : float;  (** What the owner said to renew at. *)
    mutable ticking : bool;
  }

  (* A local process asks the daemon again this often; the daemon may have
     been restarted on a build that answers. *)
  let retry_every = 30.

  (* Unanswered renewals in a row before a lessee runs its own law. *)
  let missed_before_local = 3

  let settings_for p name =
    match List.assoc_opt name p.overrides with
      | Some s -> s
      | None -> p.defaults

  let create_process ?(defaults = Uplink_control.default_settings)
      ?(overrides = []) () =
    {
      links = Hashtbl.create 4;
      defaults;
      overrides;
      mode = Local;
      daemon = None;
      missed = 0;
      retry_at = 0.;
      interval = !Uplink_control.tick_interval;
      ticking = false;
    }

  (* An owner's table for a link, split at once so a lessee renewing before
     the first step is granted an even share of the law's starting rate
     rather than nothing. *)
  let lessee_table l =
    let table = Uplink_lease.create () in
    Uplink_lease.split table ~now:(Clock.now ())
      ~total:(Uplink_control.rate l.control)
      ~min_rate:(float_of_int (Uplink_control.settings l.control).min_rate)
      ~self:Uplink_lease.idle;
    table

  let create_link p name =
    let now = Clock.now () in
    let settings = settings_for p name in
    let control = Uplink_control.create ~settings ~now () in
    let share = Uplink_budget.create ~now ~rate:(Uplink_control.rate control) in
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
    let l =
      {
        name;
        proc = p;
        control;
        share;
        line;
        lessees = None;
        completed_since;
        probes = [];
        last_timeouts = 0;
        last_state = Uplink_control.state control;
        probe_warned = false;
        used = false;
        granted_limit = None;
      }
    in
    if p.mode = Owner then l.lessees <- Some (lessee_table l);
    Hashtbl.replace p.links name l;
    l

  let link p name =
    match Hashtbl.find_opt p.links name with
      | Some l -> l
      | None -> create_link p name

  let create ?settings () =
    link (create_process ?defaults:settings ()) default_link

  let process_of l = l.proc
  let name l = l.name
  let enabled l = (Uplink_control.settings l.control).Uplink_control.enabled
  let control l = l.control
  let mode p = p.mode
  let waiting l = Queue.length l.line.waiters
  let per_sec = Log.rate

  (* A link nothing here writes to, probes, or leases: stepped and shown
     only once something does, and kept meanwhile so a job that comes back
     finds the law where it left it. *)
  let dormant l ~now =
    l.probes = [] && (not l.used)
    &&
      match l.lessees with
      | Some t -> Uplink_lease.live t ~now = []
      | None -> true

  let all_links p =
    List.sort compare (Hashtbl.fold (fun n l acc -> (n, l) :: acc) p.links [])

  let links p =
    let now = Clock.now () in
    List.filter (fun (_, l) -> not (dormant l ~now)) (all_links p)

  (* What this process says of itself on a link when it renews, or files as
     the owner's own row: what is in flight and waiting now, what completed
     and timed out since it last said. *)
  let own_report l ~timeouts ~probe =
    let r =
      {
        Uplink_lease.in_flight = Uplink_budget.in_flight_bytes l.share;
        completed = !(l.completed_since);
        timeouts;
        waiting = waiting l;
        held_back = held_back l.line;
        probe;
      }
    in
    l.completed_since := 0;
    r

  (* Summed over the stores on this link, so a timeout on another link is
     not read as this one's. *)
  let timeouts_since l =
    let n = List.fold_left (fun acc p -> acc + p.timeouts ()) 0 l.probes in
    let delta = n - l.last_timeouts in
    l.last_timeouts <- n;
    delta

  (* One small round trip to every store on the link not held down, timed on
     this clock, while anyone the law answers for has bytes in flight. A probe
     that times out is read as the timeout's length: an enormous delay, which
     the next step cuts hard on. It does not touch the store's health, which
     its own retry loop keeps. *)
  let probe_round l ~lessees_in_flight =
    let in_flight = Uplink_budget.in_flight_bytes l.share + lessees_in_flight in
    if in_flight = 0 then Io.return None
    else
      let+ delays =
        Io.map_p
          (fun p ->
            let started = Clock.now () in
            Io.catch
              (fun () ->
                let+ () = Clock.with_timeout !probe_timeout p.probe in
                Some (Clock.now () -. started))
              (fun exn ->
                if Clock.is_timeout exn then begin
                  if not l.probe_warned then begin
                    l.probe_warned <- true;
                    Log.warn
                      (Printf.sprintf
                         "uplink %s: a probe of %s went unanswered for %.0fs"
                         l.name p.name !probe_timeout)
                  end;
                  Io.return (Some !probe_timeout)
                end
                else Io.return None))
          (List.filter (fun p -> not (p.held ())) l.probes)
      in
      (* The least of the round: server-side delay is one-sided. *)
      List.fold_left
        (fun least d ->
          match (least, d) with
            | None, d -> d
            | Some a, Some b -> Some (Float.min a b)
            | least, None -> least)
        None delays

  let announce l =
    let state = Uplink_control.state l.control in
    if state <> l.last_state then begin
      l.last_state <- state;
      let rate = per_sec (Uplink_control.rate l.control) in
      match state with
        | Uplink_control.Steady ->
            Log.info
              (Printf.sprintf
                 "uplink %s: steady at %s (capacity %s, delay +%.0f ms)" l.name
                 rate
                 (match Uplink_control.capacity l.control with
                   | Some c -> per_sec c
                   | None -> "unknown")
                 (1000. *. Uplink_control.queueing_delay l.control))
        | Backing_off ->
            Log.info
              (Printf.sprintf "uplink %s: backing off to %s after a timeout"
                 l.name rate)
        | Ramping ->
            Log.info (Printf.sprintf "uplink %s: probing above %s" l.name rate)
    end

  (* {2 The owner's step on one link, and a local process's}

     Timeouts are read off the link's own stores and off what its lessees
     reported, one cut a step however many there were: no hook into the
     drivers. The law's rate is then split, the owner's own share being what
     its line admits against. *)
  let step l =
    let now = Clock.now () in
    let own_timeouts = timeouts_since l in
    let lessee_completed, lessee_timeouts =
      match l.lessees with Some t -> Uplink_lease.drain t | None -> (0, 0)
    in
    if own_timeouts + lessee_timeouts > 0 then
      Uplink_control.timed_out l.control ~now;
    (* What lessees moved is spread over the interval they reported it for. *)
    if lessee_completed > 0 then
      Uplink_control.completed l.control ~now ~bytes:lessee_completed
        ~elapsed:!Uplink_control.tick_interval;
    (* One listing a step: what is probed for, what is held back, and what
       is split are the same lessees. *)
    let lessees =
      match l.lessees with Some t -> Uplink_lease.live t ~now | None -> []
    in
    let* probe =
      probe_round l
        ~lessees_in_flight:
          (List.fold_left
             (fun acc (_, (r : Uplink_lease.report)) -> acc + r.in_flight)
             0 lessees)
    in
    let now = Clock.now () in
    Option.iter (Uplink_control.observe_delay l.control ~now) probe;
    (* One report a step, read once: what this process is to the split, and
       what it says of itself should it ask the daemon back in this step. *)
    let mine = own_report l ~timeouts:own_timeouts ~probe in
    let limited =
      Uplink_lease.wants mine
      || List.exists (fun (_, r) -> Uplink_lease.wants r) lessees
    in
    Uplink_control.tick l.control ~now ~limited;
    let total = Uplink_control.rate l.control in
    (match l.lessees with
      | Some t ->
          let min_rate =
            float_of_int (Uplink_control.settings l.control).min_rate
          in
          Uplink_lease.split t ~now ~total ~min_rate ~self:mine;
          Uplink_budget.set_rate l.share ~now (Uplink_lease.own_rate t)
      | None -> Uplink_budget.set_rate l.share ~now total);
    announce l;
    pump l.line;
    arm l.line;
    Io.return mine

  (* {2 A lessee's renewal} *)

  (* Every link this process uses, its report beside it: one line a tick
     whatever the number of links. *)
  let request (reports : (string * Uplink_lease.report) list) =
    Yojson.Safe.to_string
      (`Assoc
         [
           ("action", `String "uplink");
           ("pid", `Int (Unix.getpid ()));
           ( "links",
             `Assoc
               (List.map
                  (fun (name, r) ->
                    (name, `Assoc (Uplink_lease.report_to_json r)))
                  reports) );
         ])

  type grant = { rate : float; limit : Uplink_control.limit option }
  type answer = Granted of (string * grant) list * float | Refused | Unreached

  (* The owner's side of the same line: a grant per link, and at the top the
     first one's rate for a lessee that asked in the one-link shape. *)
  let answer_json ~flat ~interval grants =
    `Assoc
      ([
         ("ok", `Bool true);
         ("interval", `Float interval);
         ( "links",
           `Assoc
             (List.map
                (fun (name, g) ->
                  ( name,
                    `Assoc
                      (("rate", `Float g.rate)
                      ::
                        (match g.limit with
                        | Some l ->
                            [
                              ( "limit",
                                `String (Uplink_control.string_of_limit l) );
                            ]
                        | None -> [])) ))
                grants) );
       ]
      @
        match (flat, grants) with
        | true, (_, g) :: _ -> [("rate", `Float g.rate)]
        | _ -> [])

  let num fields key =
    match List.assoc_opt key fields with
      | Some (`Int n) -> Some (float_of_int n)
      | Some (`Float f) -> Some f
      | _ -> None

  (* A grant per link named, and the interval. An answer with no links, which
     a daemon of the one-link build gives, is a refusal: one grant cannot be
     read as several. *)
  let read_answer line =
    match Yojson.Safe.from_string line with
      | `Assoc fields -> (
          match (List.assoc_opt "ok" fields, List.assoc_opt "links" fields) with
            | Some (`Bool true), Some (`Assoc links) ->
                Granted
                  ( List.filter_map
                      (fun (name, g) ->
                        match g with
                          | `Assoc gf ->
                              Option.map
                                (fun rate ->
                                  ( name,
                                    {
                                      rate;
                                      limit =
                                        (match List.assoc_opt "limit" gf with
                                          | Some (`String l) ->
                                              Uplink_control.limit_of_string l
                                          | _ -> None);
                                    } ))
                                (num gf "rate")
                          | _ -> None)
                      links,
                    Option.value (num fields "interval")
                      ~default:!Uplink_control.tick_interval )
            | _ -> Refused)
      | _ | (exception _) -> Refused

  let fall_to_local p why =
    p.mode <- Local;
    p.retry_at <- Clock.now () +. retry_every;
    Log.warn
      (Printf.sprintf "uplink: %s; governing this process's links alone" why)

  (* One renewal for every link: what came back sets each link's grant, and
     what did not counts against the daemon. [Refused] is a daemon that does
     not know the action, which no retry will change soon; [Unreached] is one
     that may be back. [reports] is what this process said of itself on each
     link: a step that has just read them hands them on, so a busy process
     asking the daemon back does not report itself idle. *)
  let renew p ~send ~(reports : (string * Uplink_lease.report) list) =
    let* answer =
      Io.catch
        (fun () ->
          let+ line = send (request reports) in
          read_answer line)
        (fun _ -> Io.return Unreached)
    in
    (match answer with
      | Granted (grants, interval) ->
          p.missed <- 0;
          p.interval <- interval;
          let now = Clock.now () in
          (* A link the answer does not name keeps its last grant. *)
          List.iter
            (fun (name, g) ->
              let l = link p name in
              Uplink_budget.set_rate l.share ~now g.rate;
              l.granted_limit <- g.limit)
            grants;
          if p.mode <> Leased then begin
            p.mode <- Leased;
            Log.info
              (Printf.sprintf "uplink: leasing from the daemon: %s"
                 (String.concat ", "
                    (List.map
                       (fun (name, g) -> name ^ " " ^ per_sec g.rate)
                       grants)))
          end
      | Refused ->
          if p.mode = Leased then
            fall_to_local p "the daemon does not answer for the link"
      | Unreached ->
          p.missed <- p.missed + 1;
          if p.mode = Leased && p.missed >= missed_before_local then
            fall_to_local p
              (Printf.sprintf "%d renewals unanswered" missed_before_local));
    List.iter
      (fun (_, l) ->
        pump l.line;
        arm l.line)
      (all_links p);
    Io.return ()

  (* A local process with a daemon to ask asks it again now and then. *)
  let maybe_retry p ~reports =
    match (p.mode, p.daemon) with
      | Local, Some send when Clock.now () >= p.retry_at ->
          p.retry_at <- Clock.now () +. retry_every;
          renew p ~send ~reports
      | _ -> Io.return ()

  (* Every link something uses, its report beside it. *)
  let reports_of p f =
    let rec go acc = function
      | [] -> Io.return (List.rev acc)
      | (name, l) :: rest ->
          let* r = f l in
          go ((name, r) :: acc) rest
    in
    go [] (links p)

  (* One loop for the process whatever its mode: a lessee renews at the
     owner's interval, everyone else steps every link's law at its own. *)
  let rec ticker p =
    let* () =
      Clock.sleep
        (match p.mode with
          | Leased -> p.interval
          | Owner | Local -> !Uplink_control.tick_interval)
    in
    let* () =
      match (p.mode, p.daemon) with
        | Leased, Some send ->
            (* A lessee times its own links, and says what it saw: the owner
               may have no store on one of them to time for itself. *)
            let* reports =
              reports_of p (fun l ->
                  let+ probe = probe_round l ~lessees_in_flight:0 in
                  own_report l ~timeouts:(timeouts_since l) ~probe)
            in
            renew p ~send ~reports
        | Leased, None ->
            fall_to_local p "no daemon to renew from";
            Io.return ()
        | (Owner | Local), _ ->
            let* reports = reports_of p step in
            maybe_retry p ~reports
    in
    ticker p

  let ensure_ticking p =
    if not p.ticking then begin
      p.ticking <- true;
      Io.async (fun () -> ticker p)
    end

  (* {2 Deciding what this process is} *)

  let own p =
    p.mode <- Owner;
    p.daemon <- None;
    Hashtbl.iter
      (fun _ l -> if l.lessees = None then l.lessees <- Some (lessee_table l))
      p.links;
    ensure_ticking p

  let lease_through p ~send =
    if p.mode <> Owner then begin
      p.daemon <- Some send;
      p.mode <- Leased;
      p.missed <- 0
    end

  (* A link named by a lessee and by nothing here is made for it, on this
     process's settings for that name: its law runs on what the lessee
     reports. *)
  let lease_renewal p ~pid reports =
    match p.mode with
      | Owner ->
          let now = Clock.now () in
          let grants =
            List.map
              (fun (name, report) ->
                let l = link p name in
                let table =
                  match l.lessees with
                    | Some t -> t
                    | None ->
                        let t = lessee_table l in
                        l.lessees <- Some t;
                        t
                in
                Uplink_lease.record table ~now ~pid report;
                (* What the lessee timed is a sample beside this process's
                   own, and the only one for a link it has no store on. *)
                Option.iter
                  (Uplink_control.observe_delay l.control ~now)
                  report.Uplink_lease.probe;
                ( name,
                  {
                    rate = Uplink_lease.rate_for table ~now ~pid;
                    limit = Some (Uplink_control.limit l.control);
                  } ))
              reports
          in
          Some (grants, p.interval)
      | Leased | Local -> None

  let acquire l ~class_ ~bytes =
    l.used <- true;
    if not (enabled l) then Io.return ()
    else (
      match class_ with
        | Foreground -> Io.return ()
        | Background ->
            ensure_ticking l.proc;
            acquire l.line ~bytes)

  let try_admit l ~bytes =
    l.used <- true;
    if not (enabled l) then true
    else begin
      ensure_ticking l.proc;
      if room l.line ~bytes then true
      else begin
        l.line.held_back <- true;
        Uplink_control.dropped l.control;
        false
      end
    end

  let admission l class_ =
    {
      (admission_of l.line) with
      acquire = (fun ~bytes -> acquire l ~class_ ~bytes);
      try_admit =
        (fun ~bytes ->
          match class_ with
            | Foreground -> true
            | Background -> try_admit l ~bytes);
    }

  (* What the store has timed out so far is not this link's to cut on. *)
  let attach l ~name ~held ~timeouts ~probe =
    l.last_timeouts <- l.last_timeouts + timeouts ();
    l.probes <- { name; held; timeouts; probe } :: l.probes;
    if enabled l then ensure_ticking l.proc

  (* The budget's figures sit where a reader expects them, beside the drops,
     whichever module happens to hold them. A lessee runs no law, so it
     says so in place of a state and a capacity it does not have. *)
  let json l =
    let now = Clock.now () in
    let mode = l.proc.mode in
    List.concat_map
      (fun (k, v) ->
        match (k, mode) with
          | "state", Leased -> [(k, `String "leased")]
          | "capacityBytesPerSec", Leased -> [(k, `Null)]
          | "limit", Leased ->
              [
                ( k,
                  match l.granted_limit with
                    | Some g -> `String (Uplink_control.string_of_limit g)
                    | None -> `Null );
              ]
          | "rateBytesPerSec", Leased ->
              [(k, `Int (int_of_float (Uplink_budget.rate l.share)))]
          | "drops", _ ->
              [
                ("inFlightBytes", `Int (Uplink_budget.in_flight_bytes l.share));
                ("windowBytes", `Int (Uplink_budget.window_bytes l.share));
                (k, v);
              ]
          | _ -> [(k, v)])
      (Uplink_control.json l.control ~now)
    @ [("waiting", `Int (waiting l)); ("mode", `String (string_of_mode mode))]
    @
      match l.lessees with
      | Some t when mode = Owner ->
          [
            ( "ownRateBytesPerSec",
              `Int (int_of_float (Uplink_budget.rate l.share)) );
            ("lessees", `List (Uplink_lease.json t ~now));
          ]
      | _ -> []

  let json_links p = List.map (fun (n, l) -> (n, `Assoc (json l))) (links p)
  let the_process : process option ref = ref None

  let configure ~defaults ~overrides =
    match !the_process with
      | Some _ -> ()
      | None -> the_process := Some (create_process ~defaults ~overrides ())

  let process () =
    match !the_process with
      | Some p -> p
      | None ->
          let p = create_process () in
          the_process := Some p;
          p
end
