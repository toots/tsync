type entry = { size : int64; done_ : int64 }

type t = {
  mutable used : bool;
  mutable moving : float;
  mutable total : int64;
  mutable done_ : int64;
  mutable skipped : int64;
  mutable failed : int64;
  mutable entry : entry option;
}

let state =
  {
    used = false;
    moving = 0.;
    total = 0L;
    done_ = 0L;
    skipped = 0L;
    failed = 0L;
    entry = None;
  }

(* The throughput clock starts at the first byte handled rather than at the
   plan: a resumed run opens by finding files already in the domain, and
   averaging over that stretch answers with a rate no upload ever ran at. *)
let moved bytes =
  if bytes > 0L && state.moving = 0. then state.moving <- Unix.gettimeofday ()

let plan ~bytes =
  state.used <- true;
  state.total <- bytes

let start_entry ~size =
  state.used <- true;
  state.entry <- Some { size; done_ = 0L }

let advance ~bytes =
  match state.entry with
    | None -> ()
    | Some e ->
        state.entry <- Some { e with done_ = Int64.add e.done_ bytes };
        moved bytes

(* An entry nothing was planned for moves nothing. *)
let finish_entry outcome =
  let planned = match state.entry with None -> 0L | Some e -> e.size in
  state.entry <- None;
  match outcome with
    | `Done bytes ->
        state.done_ <- Int64.add state.done_ bytes;
        moved bytes
    | `Skipped -> state.skipped <- Int64.add state.skipped planned
    | `Failed -> state.failed <- Int64.add state.failed planned

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
    (* Averaged over the run rather than a recent window: an estimate divided by
       what the last few seconds happened to do swings by hours between reports,
       and the rolling figure is already the [traffic] row. *)
    let elapsed =
      if state.moving = 0. then 0. else Unix.gettimeofday () -. state.moving
    in
    let per_sec =
      if elapsed > 0. then Int64.to_float done_ /. elapsed else 0.
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
             ("bytesPerSecAvg", `Int (int_of_float per_sec));
           ]
          @ eta @ entry) );
    ])
