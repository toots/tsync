(* The two bounds a link budget keeps, read at chosen instants.

   The clock is a number handed in, so what is pinned is the decision at each
   instant rather than how long anything took: a bucket that refills at its
   rate and no faster, a body that is admitted on a full bucket however large
   and paid off before the next, and a window that stops a body from queueing
   behind more than the stall timeout can carry. *)

open Check

let () =
  Uplink_budget.burst_seconds := 2.;
  Uplink_budget.stall_timeout := 60.;
  Uplink_budget.window_safety := 0.5;

  case "a bucket refills at its rate, starts full, and holds no more";
  let b = Uplink_budget.create ~now:0. ~rate:1000. in
  check "full at birth: two seconds of rate"
    (Uplink_budget.tokens b ~now:0. = 2000.);
  check "admits what it holds" (Uplink_budget.admits b ~now:0. ~bytes:2000);
  Uplink_budget.take b ~now:0. ~bytes:2000;
  check "and then nothing" (not (Uplink_budget.admits b ~now:0. ~bytes:1));
  check "a byte is a millisecond away"
    ~why:(fun () -> string_of_float (Uplink_budget.wait_for b ~now:0. ~bytes:1))
    (Float.abs (Uplink_budget.wait_for b ~now:0. ~bytes:1 -. 0.001) < 1e-9);
  check "a second later, a second's worth"
    (Uplink_budget.tokens b ~now:1. = 1000.);
  check "a minute later, still only the depth"
    (Uplink_budget.tokens b ~now:60. = 2000.);

  case "a body larger than the bucket is admitted once, then paid off";
  let b = Uplink_budget.create ~now:0. ~rate:1000. in
  check "a full bucket admits five times its depth"
    (Uplink_budget.admits b ~now:0. ~bytes:5000);
  Uplink_budget.take b ~now:0. ~bytes:5000;
  check "leaving it owing" (Uplink_budget.tokens b ~now:0. = -3000.);
  check "the next byte waits the debt out, plus its own"
    ~why:(fun () -> string_of_float (Uplink_budget.wait_for b ~now:0. ~bytes:1))
    (Float.abs (Uplink_budget.wait_for b ~now:0. ~bytes:1 -. 3.001) < 1e-9);
  Uplink_budget.release b ~bytes:5000;
  check "and is refused until then"
    (not (Uplink_budget.admits b ~now:3. ~bytes:1));
  check "five seconds on, the long run has held: 5000 bytes in 5 seconds"
    (Uplink_budget.admits b ~now:5. ~bytes:1);

  case "the window: nothing queues behind more than the stall can carry";
  (* A rate deep enough that the bucket never speaks here: 200 KB of burst
     against bodies read at instants when it is full. *)
  let b = Uplink_budget.create ~now:0. ~rate:100_000. in
  check "a window of half the stall at the rate"
    ~why:(fun () -> string_of_int (Uplink_budget.window_bytes b))
    (Uplink_budget.window_bytes b = 3_000_000);
  check "one body always goes alone, however large"
    (Uplink_budget.admits b ~now:0. ~bytes:10_000_000);
  Uplink_budget.take b ~now:0. ~bytes:10_000_000;
  check "and while it is in flight nothing joins it"
    (not (Uplink_budget.admits b ~now:1000. ~bytes:1));
  check "which no wait fixes"
    (Uplink_budget.wait_for b ~now:1000. ~bytes:1 = infinity);
  Uplink_budget.release b ~bytes:10_000_000;
  check "once it has left, the way is clear"
    (Uplink_budget.admits b ~now:1000. ~bytes:1);
  Uplink_budget.take b ~now:1000. ~bytes:2_000_000;
  check "a second body fits inside the window"
    (Uplink_budget.admits b ~now:1100. ~bytes:900_000);
  check "a body that would overfill it does not"
    (not (Uplink_budget.admits b ~now:1100. ~bytes:1_100_000));

  case "the rate can change under a bucket";
  let b = Uplink_budget.create ~now:0. ~rate:1000. in
  Uplink_budget.take b ~now:0. ~bytes:2000;
  Uplink_budget.set_rate b ~now:1. 4000.;
  check "what the old rate earned is kept"
    (Uplink_budget.tokens b ~now:1. = 1000.);
  check "the new rate fills from there" (Uplink_budget.tokens b ~now:2. = 5000.);
  check "and caps at its own depth" (Uplink_budget.tokens b ~now:10. = 8000.);
  check "the window follows the rate" (Uplink_budget.window_bytes b = 120_000);
  Uplink_budget.set_rate b ~now:10. 500.;
  check "a rate cut clips the bucket to the new depth"
    (Uplink_budget.tokens b ~now:10. = 1000.);
  check "a rate of nothing is a byte a second"
    (Uplink_budget.rate (Uplink_budget.create ~now:0. ~rate:0.) = 1.);

  case "the stall timeout is one setting, read live";
  let b = Uplink_budget.create ~now:0. ~rate:1000. in
  Uplink_budget.stall_timeout := 10.;
  check "a shorter stall, a smaller window"
    ~why:(fun () -> string_of_int (Uplink_budget.window_bytes b))
    (Uplink_budget.window_bytes b = 5000);
  Uplink_budget.stall_timeout := 60.;

  report ~expected:25 ()
