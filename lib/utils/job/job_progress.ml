type entry = { size : int64; done_ : int64 }

type t = {
  mutable used : bool;
  mutable total : int64;
  mutable done_ : int64;
  mutable skipped : int64;
  mutable failed : int64;
  mutable entry : entry option;
  rate : Metrics.counter;
}

let state =
  {
    used = false;
    total = 0L;
    done_ = 0L;
    skipped = 0L;
    failed = 0L;
    entry = None;
    rate = Metrics.counter ();
  }

let count bytes =
  if bytes > 0L then Metrics.count state.rate (Int64.to_int bytes)

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
        count bytes

(* An entry nothing was planned for moves nothing but the rate. *)
let finish_entry outcome =
  let planned, reported =
    match state.entry with None -> (0L, 0L) | Some e -> (e.size, e.done_)
  in
  state.entry <- None;
  match outcome with
    | `Done bytes ->
        state.done_ <- Int64.add state.done_ bytes;
        (* Whatever of the entry no chunk accounted for, so an entry handled
           without per-chunk reports still moves the rate. *)
        count (Int64.sub bytes reported)
    | `Skipped -> state.skipped <- Int64.add state.skipped planned
    | `Failed -> state.failed <- Int64.add state.failed planned

let int64 v = `Int (Int64.to_int v)

(* Absent figures are absent keys: an unknown estimate is not zero seconds,
   and no entry in flight is not an empty one. *)
let json () =
  if not state.used then []
  else (
    let handled =
      Int64.add state.done_ (Int64.add state.skipped state.failed)
    in
    let remaining = max 0L (Int64.sub state.total handled) in
    let per_sec = Metrics.rate state.rate in
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
             ("bytesDone", int64 state.done_);
             ("bytesSkipped", int64 state.skipped);
             ("bytesFailed", int64 state.failed);
             ("bytesRemaining", int64 remaining);
             ("bytesPerSec", `Int (int_of_float per_sec));
           ]
          @ eta @ entry) );
    ])
