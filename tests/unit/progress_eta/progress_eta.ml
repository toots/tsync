(* What a run's estimate is divided by.

   An import is transfer-bound and a mirror is not: a mirror asks each
   destination what it holds and mostly it holds it, so an estimate against the
   bytes that moved answers with hours of transfer for a run that has minutes of
   checking left.

   The clock here is the real one, so what is pinned is a ratio -- the remainder
   at the rate the run has been going -- which holds however slow the machine
   running this is. *)

open Check

let progress key =
  match Job.Progress.json () with
    | [("progress", `Assoc fields)] -> (
        match List.assoc_opt key fields with None -> `Null | Some v -> v)
    | _ -> `Null

let num key =
  match progress key with `Float f -> f | `Int n -> float_of_int n | _ -> 0.

let present key = progress key <> `Null

let () =
  (* A mirror of a thousand bytes' worth of objects. *)
  let planned_at = Unix.gettimeofday () in
  Job.Progress.plan ~basis:`Handled ~bytes:1000L;

  case "before anything is examined";
  check "a run with nothing behind it has no estimate to give"
    (not (present "etaSeconds"));
  check "and says so rather than answering zero seconds"
    (progress "etaSeconds" = `Null);

  (* Long enough that the elapsed the estimate divides by is a real figure
     rather than a rounding of zero. *)
  Unix.sleepf 0.3;

  case "four hundred bytes' worth found already in place";
  (* The mirror case: nothing was transferred, and the run is still 40% of the
     way through what it set out to do. *)
  Job.Progress.settle ~bytes:400L ~sent:0L `Skipped;
  (* Read before the clock, so the elapsed compared against is never the
     shorter of the two. *)
  let eta = num "etaSeconds" in
  let elapsed = Unix.gettimeofday () -. planned_at in
  check "the estimate exists although nothing was transferred"
    ~why:(fun () -> Printf.sprintf "sent %.0f" (num "bytesSent"))
    (present "etaSeconds" && num "bytesSent" = 0.);
  (* 600 left at 400 per elapsed: the remainder takes half again as long as
     what is behind it. *)
  check "and is the remainder at the rate the run has been going"
    ~why:(fun () -> Printf.sprintf "%.3fs estimated, %.3fs elapsed" eta elapsed)
    (eta <= 1.5 *. elapsed && eta >= 1.5 *. (elapsed -. 0.1));
  check "the rate is what it got through, not what it moved"
    ~why:(fun () -> Printf.sprintf "%.0f/s" (num "bytesPerSecAvg"))
    (num "bytesPerSecAvg" > 0.);
  check "and the fraction counts what was already there"
    (num "bytesHandled" = 400. && num "bytesSkipped" = 400.);

  case "the rest of it copied";
  Job.Progress.settle ~bytes:600L ~sent:600L `Done;
  check "what moved and what the run got through are separate figures"
    (num "bytesSent" = 600. && num "bytesHandled" = 1000.);
  check "and a run with nothing left estimates nothing"
    (num "bytesRemaining" = 0. && not (present "etaSeconds"));

  report ~expected:8 ()
