let stall_timeout = ref 60.
let window_safety = ref 0.5
let burst_seconds = ref 2.

type t = {
  mutable rate : float;
  mutable tokens : float;
  mutable filled_at : float;
  mutable in_flight : int;
}

let floor_rate rate = if rate < 1. then 1. else rate
let burst t = t.rate *. !burst_seconds

(* Earned since the last look, capped at the depth: a bucket left alone does
   not go on filling forever. The clock only moves forward, but a reading from
   before the last fill is not paid twice. *)
let refill t ~now =
  let elapsed = now -. t.filled_at in
  if elapsed > 0. then begin
    t.tokens <- Float.min (burst t) (t.tokens +. (t.rate *. elapsed));
    t.filled_at <- now
  end

let create ~now ~rate =
  let rate = floor_rate rate in
  { rate; tokens = rate *. !burst_seconds; filled_at = now; in_flight = 0 }

let set_rate t ~now rate =
  refill t ~now;
  t.rate <- floor_rate rate;
  t.tokens <- Float.min (burst t) t.tokens

let rate t = t.rate

let tokens t ~now =
  refill t ~now;
  t.tokens

let in_flight_bytes t = t.in_flight
let window_bytes t = int_of_float (t.rate *. !stall_timeout *. !window_safety)

(* A body larger than the bucket is admitted on a full bucket rather than
   never; what it takes beyond that is owed, and paid off before the next. *)
let asks t bytes = Float.min (float_of_int bytes) (burst t)

let window_has_room t bytes =
  t.in_flight = 0 || t.in_flight + bytes <= window_bytes t

let admits t ~now ~bytes =
  refill t ~now;
  t.tokens >= asks t bytes && window_has_room t bytes

let take t ~now ~bytes =
  refill t ~now;
  t.tokens <- t.tokens -. float_of_int bytes;
  t.in_flight <- t.in_flight + bytes

let release t ~bytes = t.in_flight <- Int.max 0 (t.in_flight - bytes)

let wait_for t ~now ~bytes =
  refill t ~now;
  if not (window_has_room t bytes) then infinity
  else (
    let short = asks t bytes -. t.tokens in
    if short <= 0. then 0. else short /. t.rate)
