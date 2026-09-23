type t = {
  tracked : bool;
  mutable consecutive : int;
  mutable held_until : float;
  mutable hold : float;
  mutable reason : string;
  mutable sampled : bool;
  mutable failing_since : float;
  mutable last_lost : float;
  mutable probing : bool;
  mutable next_watch : int;
  watchers : (int, unit -> unit) Hashtbl.t;
  mutable timeouts : int;
}

let trip_after = ref 2
let trip_span = ref 1.
let hold_initial = ref 30.
let hold_max = ref 300.
let probe_timeout = ref 10.

let make ~tracked =
  {
    tracked;
    consecutive = 0;
    held_until = 0.;
    hold = !hold_initial;
    reason = "";
    sampled = not tracked;
    failing_since = 0.;
    last_lost = 0.;
    probing = false;
    next_watch = 0;
    watchers = Hashtbl.create 4;
    timeouts = 0;
  }

let always_up = make ~tracked:false
let create () = make ~tracked:true

(* A tally apart from the trip: whoever governs the link this member is on
   reads it, and a timeout is evidence for the link whether or not it took
   the member out. The untracked cell is shared, so it counts nothing. *)
let timed_out t = if t.tracked then t.timeouts <- t.timeouts + 1
let timeouts t = t.timeouts
let now = Unix.gettimeofday
let out t = t.held_until > 0.
let is_held t = out t && now () < t.held_until
let is_down = out
let sampled t = t.sampled

let check t =
  if not (out t) then `Up
  else if now () < t.held_until then `Held
  else begin
    t.held_until <- now () +. t.hold;
    t.probing <- true;
    `Probe
  end

let answered t =
  if t.tracked then begin
    t.sampled <- true;
    t.consecutive <- 0;
    t.probing <- false;
    t.held_until <- 0.;
    t.hold <- !hold_initial
  end

let on_held t told =
  let id = t.next_watch in
  t.next_watch <- id + 1;
  if t.tracked then Hashtbl.replace t.watchers id told;
  id

let off t id = Hashtbl.remove t.watchers id

let tell t =
  let told = Hashtbl.fold (fun _ f acc -> f :: acc) t.watchers [] in
  Hashtbl.reset t.watchers;
  List.iter (fun f -> f ()) told

let hold_for t seconds =
  t.hold <- seconds;
  t.held_until <- now () +. seconds

(* A request already on its way when the member went out fails into a hold
   that is none of its doing, and only the probe's failure is news; past the
   hold every failure is one, nobody having to have asked for a probe.

   Failures a hold's length apart are not a run: the first says nothing about
   the link by the time the second comes. *)
let lost t reason =
  if not t.tracked then `Up
  else begin
    let at = now () in
    t.sampled <- true;
    t.reason <- reason;
    if t.consecutive = 0 || ((not (out t)) && at -. t.last_lost > !hold_initial)
    then begin
      t.consecutive <- 0;
      t.failing_since <- at
    end;
    t.last_lost <- at;
    t.consecutive <- t.consecutive + 1;
    if out t then
      if t.probing || at >= t.held_until then begin
        t.probing <- false;
        hold_for t (Float.min !hold_max (t.hold *. 2.));
        tell t;
        `Tripped
      end
      else `Held
    else if t.consecutive >= !trip_after && at -. t.failing_since >= !trip_span
    then begin
      hold_for t !hold_initial;
      tell t;
      `Tripped
    end
    else `Up
  end

(* The hold [lost] would have chosen, taken on one report rather than a run. *)
let probe_lost t reason =
  if t.tracked then begin
    let at = now () in
    let held = out t in
    t.sampled <- true;
    t.reason <- reason;
    if t.consecutive = 0 then t.failing_since <- at;
    t.consecutive <- t.consecutive + 1;
    t.last_lost <- at;
    t.probing <- false;
    hold_for t
      (if held then Float.min !hold_max (t.hold *. 2.) else !hold_initial);
    tell t
  end

let describe t =
  if not (out t) then ""
  else
    Printf.sprintf "held down for %.0fs after %d failure%s (%s)"
      (Float.max 0. (t.held_until -. now ()))
      t.consecutive
      (if t.consecutive = 1 then "" else "s")
      t.reason

let clock at =
  let tm = Unix.localtime at in
  Printf.sprintf "%02d:%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let json t =
  if not (out t) then []
  else
    [
      ( "health",
        `Assoc
          [
            ("heldUntil", `Float t.held_until);
            ("heldUntilLocal", `String (clock t.held_until));
            ("heldSeconds", `Float (Float.max 0. (t.held_until -. now ())));
            ("failures", `Int t.consecutive);
            ("reason", `String t.reason);
          ] );
    ]

let expire t = if out t then t.held_until <- now ()
let hold_length t = t.hold
