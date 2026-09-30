type report = {
  in_flight : int;
  completed : float;
  timeouts : int;
  waiting : int;
  held_back : bool;
  probes : (string * float) list;
}

let idle =
  {
    in_flight = 0;
    completed = 0.;
    timeouts = 0;
    waiting = 0;
    held_back = false;
    probes = [];
  }

let wants r = r.waiting > 0 || r.held_back

let split ~total ~min_rate ~interval rows =
  let n = List.length rows in
  if n = 0 then []
  else (
    let floor = Float.min min_rate (total /. float_of_int n) in
    let cap r =
      if wants r then infinity
      else if r.in_flight > 0 then
        Float.max floor (1.25 *. r.completed /. interval)
      else floor
    in
    let by_cap =
      List.stable_sort
        (fun (_, a) (_, b) -> Float.compare a b)
        (List.mapi (fun i r -> (i, cap r)) rows)
    in
    let shares = Array.make n 0. in
    let remaining, _ =
      List.fold_left
        (fun (remaining, left) (i, cap) ->
          let share =
            Float.max floor (Float.min cap (remaining /. float_of_int left))
          in
          shares.(i) <- share;
          (Float.max 0. (remaining -. share), left - 1))
        (total, n) by_cap
    in
    let extra = remaining /. float_of_int n in
    Array.to_list (Array.map (fun s -> s +. extra) shares))

let default_link = "wan"

type request = { pid : int; links : (string * report) list; flat : bool }

let report_to_json r : Yojson.Safe.t =
  let least =
    List.fold_left (fun acc (_, d) -> Float.min acc d) infinity r.probes
  in
  `Assoc
    ([
       ("inFlight", `Int r.in_flight);
       ("completed", `Float r.completed);
       ("timeouts", `Int r.timeouts);
       ("waiting", `Int r.waiting);
       ("heldBack", `Bool r.held_back);
     ]
    @
    if r.probes = [] then []
    else
      [
        ("probeMs", `Float (least *. 1000.));
        ( "probesMs",
          `Assoc (List.map (fun (s, d) -> (s, `Float (d *. 1000.))) r.probes) );
      ])

let request_to_json r : Yojson.Safe.t =
  `Assoc
    [
      ("action", `String "uplink");
      ("pid", `Int r.pid);
      ("links", `Assoc (List.map (fun (l, r) -> (l, report_to_json r)) r.links));
    ]

let number = function
  | `Int i -> Some (float_of_int i)
  | `Float f -> Some f
  | `Intlit s -> float_of_string_opt s
  | _ -> None

let field k = function `Assoc l -> List.assoc_opt k l | _ -> None
let num k j = Option.bind (field k j) number

let report_of_json j =
  let in_flight = Option.fold ~none:0 ~some:truncate (num "inFlight" j) in
  let probes =
    match field "probesMs" j with
      | Some (`Assoc l) ->
          List.filter_map
            (fun (s, d) -> Option.map (fun d -> (s, d /. 1000.)) (number d))
            l
      | _ -> (
          match num "probeMs" j with Some d -> [("", d /. 1000.)] | None -> [])
  in
  {
    in_flight;
    completed = Option.value ~default:0. (num "completed" j);
    timeouts = Option.fold ~none:0 ~some:truncate (num "timeouts" j);
    waiting = Option.fold ~none:0 ~some:truncate (num "waiting" j);
    held_back =
      (match field "heldBack" j with Some (`Bool b) -> b | _ -> in_flight > 0);
    probes;
  }

let request_of_json j =
  match num "pid" j with
    | None -> None
    | Some pid -> (
        let pid = truncate pid in
        match field "links" j with
          | Some (`Assoc l) ->
              Some
                {
                  pid;
                  links = List.map (fun (k, r) -> (k, report_of_json r)) l;
                  flat = false;
                }
          | _ ->
              Some
                { pid; links = [(default_link, report_of_json j)]; flat = true }
        )

type grant = { rate : float; limit : Uplink_law.limit }
type answer = { interval : float; grants : (string * grant) list; flat : bool }

let limits =
  [
    (Uplink_law.Configured, "configured");
    (Measured, "measured");
    (Estimating, "estimating");
  ]

let answer_to_json a : Yojson.Safe.t =
  let links =
    List.map
      (fun (l, g) ->
        ( l,
          `Assoc
            [
              ("rate", `Float g.rate);
              ("limit", `String (List.assoc g.limit limits));
            ] ))
      a.grants
  in
  let top =
    match (a.flat, List.assoc_opt default_link a.grants) with
      | true, Some g -> [("rate", `Float g.rate)]
      | _ -> []
  in
  `Assoc
    ([("ok", `Bool true); ("interval", `Float a.interval)]
    @ top
    @ [("links", `Assoc links)])

let answer_of_json j =
  match field "links" j with
    | Some (`Assoc l) ->
        Some
          {
            interval = Option.value ~default:2. (num "interval" j);
            flat = false;
            grants =
              List.filter_map
                (fun (k, g) ->
                  Option.map
                    (fun rate ->
                      let limit =
                        match field "limit" g with
                          | Some (`String s) -> (
                              match
                                List.find_opt (fun (_, n) -> n = s) limits
                              with
                                | Some (l, _) -> l
                                | None -> Uplink_law.Estimating)
                          | _ -> Uplink_law.Estimating
                      in
                      (k, { rate; limit }))
                    (num "rate" g))
                l;
          }
    | _ -> None
