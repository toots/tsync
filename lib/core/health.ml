let trip_after = 2
let trip_span = 1.
let hold_initial = 30.
let hold_max = 300.
let probe_timeout = 10.

type t = {
  m : Mutex.t;
  name : string;
  always_up : bool;
  now : unit -> float;
  mutable consecutive : int;
  mutable failing_since : float;
  mutable last_lost : float;
  mutable held_until : float option;
  mutable hold : float;
  mutable probing : bool;
  mutable timeouts : int;
  mutable reason : string;
  mutable watchers : (unit -> unit) list;
}

let create ?(now = Rt.now) name =
  {
    m = Mutex.create ();
    name;
    always_up = false;
    now;
    consecutive = 0;
    failing_since = 0.;
    last_lost = neg_infinity;
    held_until = None;
    hold = hold_initial;
    probing = false;
    timeouts = 0;
    reason = "";
    watchers = [];
  }

let always_up = { (create "always-up") with always_up = true }
let name t = t.name

let fire t =
  let ws = t.watchers in
  t.watchers <- [];
  ws

let notify ws = List.iter (fun f -> try f () with _ -> ()) ws

let go_out t now hold =
  t.hold <- hold;
  t.held_until <- Some (now +. hold);
  t.probing <- false;
  fire t

let lost ?(reason = "") t =
  if t.always_up then `Up
  else (
    let r, ws =
      Mutex.protect t.m (fun () ->
          let now = t.now () in
          if reason <> "" then t.reason <- reason;
          let out = t.held_until <> None in
          if
            t.consecutive = 0 || ((not out) && now -. t.last_lost > hold_initial)
          then (
            t.consecutive <- 0;
            t.failing_since <- now);
          t.consecutive <- t.consecutive + 1;
          t.last_lost <- now;
          match t.held_until with
            | Some until ->
                if t.probing || now >= until then
                  (`Tripped, go_out t now (min hold_max (2. *. t.hold)))
                else (`Held, [])
            | None ->
                if
                  t.consecutive >= trip_after
                  && now -. t.failing_since >= trip_span
                then (`Tripped, go_out t now hold_initial)
                else (`Up, []))
    in
    notify ws;
    r)

let check t =
  if t.always_up then `Up
  else
    Mutex.protect t.m (fun () ->
        match t.held_until with
          | None -> `Up
          | Some until ->
              let now = t.now () in
              if now < until then `Held
              else (
                t.held_until <- Some (now +. t.hold);
                t.probing <- true;
                `Probe))

let is_held t =
  Mutex.protect t.m (fun () ->
      match t.held_until with Some u -> t.now () < u | None -> false)

let is_down t = Mutex.protect t.m (fun () -> t.held_until <> None)

let answered t =
  if not t.always_up then
    Mutex.protect t.m (fun () ->
        t.consecutive <- 0;
        t.held_until <- None;
        t.hold <- hold_initial;
        t.probing <- false)

let probe_lost ?(reason = "") t =
  if not t.always_up then
    notify
      (Mutex.protect t.m (fun () ->
           if reason <> "" then t.reason <- reason;
           let now = t.now () in
           let hold =
             if t.held_until <> None then min hold_max (2. *. t.hold)
             else hold_initial
           in
           go_out t now hold))

let on_trip t f =
  if not t.always_up then
    Mutex.protect t.m (fun () -> t.watchers <- f :: t.watchers)

let timed_out t = Mutex.protect t.m (fun () -> t.timeouts <- t.timeouts + 1)
let timeouts t = Mutex.protect t.m (fun () -> t.timeouts)

let describe t =
  Mutex.protect t.m (fun () ->
      match t.held_until with
        | None -> None
        | Some until ->
            let left = max 0. (until -. t.now ()) in
            Some
              (Printf.sprintf "held down for %.0fs after %d failures%s" left
                 t.consecutive
                 (if t.reason = "" then "" else " (" ^ t.reason ^ ")")))

type state =
  | Up
  | Down of { held_for : float; failures : int; reason : string }

let state t =
  Mutex.protect t.m (fun () ->
      match t.held_until with
        | None -> Up
        | Some until ->
            Down
              {
                held_for = max 0. (until -. t.now ());
                failures = t.consecutive;
                reason = t.reason;
              })

let state_to_yojson = function
  | Up -> `Assoc [("state", `String "up")]
  | Down d ->
      `Assoc
        [
          ("state", `String "down");
          ("heldForSeconds", `Float d.held_for);
          ("failures", `Int d.failures);
          ("reason", `String d.reason);
        ]

let state_of_yojson = function
  | `Assoc l -> (
      let num k =
        match List.assoc_opt k l with
          | Some (`Float f) -> f
          | Some (`Int i) -> float_of_int i
          | _ -> 0.
      in
      match List.assoc_opt "state" l with
        | Some (`String "down") ->
            Ok
              (Down
                 {
                   held_for = num "heldForSeconds";
                   failures = truncate (num "failures");
                   reason =
                     (match List.assoc_opt "reason" l with
                       | Some (`String r) -> r
                       | _ -> "");
                 })
        | _ -> Ok Up)
  | _ -> Error "health: not an object"
