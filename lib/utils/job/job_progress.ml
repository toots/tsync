type entry = { size : int64; done_ : int64 }

type t = {
  mutable used : bool;
  mutable basis : [ `Sent | `Handled ];
  mutable planned_at : float;
  mutable moving : float;
  mutable total : int64;
  mutable done_ : int64;
  mutable sent : int64;
  mutable skipped : int64;
  mutable failed : int64;
  mutable entry : entry option;
}

let state =
  {
    used = false;
    basis = `Sent;
    planned_at = 0.;
    moving = 0.;
    total = 0L;
    done_ = 0L;
    sent = 0L;
    skipped = 0L;
    failed = 0L;
    entry = None;
  }

(* Only bytes that reached a store, timed from the first of them: a resumed run
   opens by finding files and chunks it already has, and dividing by that
   stretch answers with a rate no transfer ever ran at. *)
let transferred bytes =
  if bytes > 0L then (
    if state.moving = 0. then state.moving <- Unix.gettimeofday ();
    state.sent <- Int64.add state.sent bytes)

let plan ~basis ~bytes =
  state.used <- true;
  state.basis <- basis;
  state.planned_at <- Unix.gettimeofday ();
  state.total <- bytes

let start_entry ~size =
  state.used <- true;
  state.entry <- Some { size; done_ = 0L }

let advance ~bytes ~sent =
  match state.entry with
    | None -> ()
    | Some e ->
        state.entry <- Some { e with done_ = Int64.add e.done_ bytes };
        if sent then transferred bytes

let settle ~bytes ~sent outcome =
  state.used <- true;
  transferred sent;
  match outcome with
    | `Done -> state.done_ <- Int64.add state.done_ bytes
    | `Skipped -> state.skipped <- Int64.add state.skipped bytes
    | `Failed -> state.failed <- Int64.add state.failed bytes

(* An entry nothing was planned for moves nothing. *)
let finish_entry outcome =
  let planned = match state.entry with None -> 0L | Some e -> e.size in
  state.entry <- None;
  match outcome with
    | `Done bytes -> settle ~bytes ~sent:0L `Done
    | `Skipped -> settle ~bytes:planned ~sent:0L `Skipped
    | `Failed -> settle ~bytes:planned ~sent:0L `Failed

let int64 v = `Int (Int64.to_int v)

(* Absent figures are absent keys: an unknown estimate is not zero seconds,
   and no entry in flight is not an empty one. *)
let json () =
  if not state.used then []
  else (
    (* The entry in flight counts as done: its chunks are on the store, and a
       run whose next file is a large one would otherwise report nothing moving
       for as long as that file takes. *)
    let done_ =
      Int64.add state.done_
        (match state.entry with None -> 0L | Some e -> e.done_)
    in
    let handled = Int64.add done_ (Int64.add state.skipped state.failed) in
    let remaining = max 0L (Int64.sub state.total handled) in
    (* Averaged over the run rather than over a recent window: an estimate
       divided by what the last few seconds happened to do swings by hours
       between reports, and the rolling figure is already the [traffic] row.

       Which figure it divides is the command's to say: a transfer extrapolates
       from what it sent, and a run whose entries are mostly already in place
       extrapolates from what it got through, there being no transfer to
       extrapolate from at all. *)
    let moved, since =
      match state.basis with
        | `Sent -> (state.sent, state.moving)
        | `Handled -> (handled, state.planned_at)
    in
    let elapsed = if since = 0. then 0. else Unix.gettimeofday () -. since in
    let per_sec =
      if elapsed > 0. then Int64.to_float moved /. elapsed else 0.
    in
    let rated_on =
      match state.basis with `Sent -> "sent" | `Handled -> "handled"
    in
    let eta =
      if per_sec > 0. && remaining > 0L then
        [("etaSeconds", `Float (Int64.to_float remaining /. per_sec))]
      else []
    in
    let entry =
      match state.entry with
        | None -> []
        | Some e ->
            [
              ( "current",
                `Assoc
                  [("bytesDone", int64 e.done_); ("bytesTotal", int64 e.size)]
              );
            ]
    in
    [
      ( "progress",
        `Assoc
          ([
             ("bytesTotal", int64 state.total);
             ("bytesDone", int64 done_);
             ("bytesSkipped", int64 state.skipped);
             ("bytesFailed", int64 state.failed);
             (* What is behind the run whatever became of it, which is the
                figure a fraction of the plan is measured in: a resumed import
                is most of the way through its tree with nothing uploaded. *)
             ("bytesHandled", int64 handled);
             ("bytesRemaining", int64 remaining);
             (* What the run transferred, which is not what it got through:
                a copy of what a store already holds moves nothing. *)
             ("bytesSent", int64 state.sent);
             ("bytesPerSecAvg", `Int (int_of_float per_sec));
             (* Which figure that rate is of, so a reader is not left to take it
                for the transfer the [traffic] row reports. *)
             ("ratedOn", `String rated_on);
           ]
          @ eta @ entry) );
    ])
