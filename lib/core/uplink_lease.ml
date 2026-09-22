type report = { in_flight : int; completed : int; timeouts : int; waiting : int }

let idle = { in_flight = 0; completed = 0; timeouts = 0; waiting = 0 }

let report_of_json fields =
  let int key =
    match List.assoc_opt key fields with
      | Some (`Int n) -> n
      | Some (`Float f) -> int_of_float f
      | _ -> 0
  in
  {
    in_flight = int "inFlight";
    completed = int "completed";
    timeouts = int "timeouts";
    waiting = int "waiting";
  }

type lessee = {
  mutable last : report;
  mutable seen : float;
  mutable grant : float option;
}

type t = {
  lessees : (int, lessee) Hashtbl.t;
  mutable completed : int;
  mutable timeouts : int;
  mutable own : float option;
  mutable last_total : float;
  mutable last_min : float;
}

let create () =
  {
    lessees = Hashtbl.create 4;
    completed = 0;
    timeouts = 0;
    own = None;
    last_total = 0.;
    last_min = 0.;
  }

let interval () = !Uplink_control.tick_interval

let record t ~now ~pid (report : report) =
  t.completed <- t.completed + report.completed;
  t.timeouts <- t.timeouts + report.timeouts;
  match Hashtbl.find_opt t.lessees pid with
    | Some l ->
        l.last <- report;
        l.seen <- now
    | None ->
        Hashtbl.replace t.lessees pid
          { last = report; seen = now; grant = None }

(* Three intervals of silence, and the row is dropped here rather than left
   for a reader to age out. *)
let live t ~now =
  let stale = 3. *. interval () in
  Hashtbl.filter_map_inplace
    (fun _ l -> if now -. l.seen > stale then None else Some l)
    t.lessees;
  List.sort compare
    (Hashtbl.fold (fun pid l acc -> (pid, l.last) :: acc) t.lessees [])

let in_flight t ~now =
  List.fold_left (fun acc (_, r) -> acc + r.in_flight) 0 (live t ~now)

let drain t =
  let out = (t.completed, t.timeouts) in
  t.completed <- 0;
  t.timeouts <- 0;
  out

(* What a lessee could use, from what it says. A line behind it: all it can
   get. Moving bytes with nothing waiting: a little over what it moved, since
   more would sit idle. Moving nothing: the floor, so a first body goes. *)
let can_use ~min_rate (r : report) =
  if r.waiting > 0 then infinity
  else if r.in_flight > 0 then
    Float.max min_rate (1.25 *. float_of_int r.completed /. interval ())
  else min_rate

(* Water-filling: the least able first, each given the lesser of what it can
   use and an even share of what is left. What remains after everyone is
   handed out evenly regardless. *)
let water_fill ~total ~min_rate wants =
  let n = List.length wants in
  let sorted =
    List.sort (fun (_, a) (_, b) -> compare a b) wants
  in
  let remaining = ref total and left = ref n in
  let grants =
    List.map
      (fun (who, cap) ->
        let share = Float.min cap (!remaining /. float_of_int !left) in
        let share = Float.max min_rate share in
        remaining := Float.max 0. (!remaining -. share);
        decr left;
        (who, share))
      sorted
  in
  let extra = if n = 0 then 0. else !remaining /. float_of_int n in
  List.map (fun (who, share) -> (who, share +. extra)) grants

let split t ~now ~total ~min_rate ~self =
  t.last_total <- total;
  t.last_min <- min_rate;
  let lessees = live t ~now in
  let wants =
    (`Own, can_use ~min_rate self)
    :: List.map (fun (pid, r) -> (`Lessee pid, can_use ~min_rate r)) lessees
  in
  List.iter
    (fun (who, rate) ->
      match who with
        | `Own -> t.own <- Some rate
        | `Lessee pid -> (
            match Hashtbl.find_opt t.lessees pid with
              | Some l -> l.grant <- Some rate
              | None -> ()))
    (water_fill ~total ~min_rate wants)

let own_rate t = match t.own with Some r -> r | None -> t.last_total

(* A newcomer since the last split: an even share of it, the floor at least,
   rather than nothing until the owner's next step. *)
let rate_for t ~now ~pid =
  match Hashtbl.find_opt t.lessees pid with
    | Some { grant = Some r; _ } -> r
    | _ ->
        let n = float_of_int (1 + List.length (live t ~now)) in
        Float.max t.last_min (t.last_total /. n)

let json t ~now =
  List.map
    (fun (pid, (r : report)) ->
      `Assoc
        [
          ("pid", `Int pid);
          ("rateBytesPerSec", `Int (int_of_float (rate_for t ~now ~pid)));
          ("inFlightBytes", `Int r.in_flight);
          ("waiting", `Int r.waiting);
        ])
    (live t ~now)
