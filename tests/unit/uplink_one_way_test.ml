(* uplink-governor G10: a queue in the download direction lowers the rate only
   on a link whose probes are all round trips. *)
open Tsync_store
module L = Uplink_law

let p fmt = Printf.printf (fmt ^^ "\n%!")
let mib = 1024. *. 1024.

let settings =
  { L.headroom = 0.8; target_delay = 0.05; min_rate = 65536.; max_rate = None }

(* A fluid bottleneck as in uplink_law_test, plus a standing queue on the
   answer path that uploads cannot drain. *)
type sim = {
  law : L.t;
  capacity : float;
  mutable now : float;
  mutable sent : float;
  mutable queue : float;
  mutable competitor : float;
  mutable answer_queue : float;
  mutable epoch : string;
  mutable offset : float;
  stamping : bool;
}

let sim ~stamping () =
  {
    law = L.create settings ~now:0.;
    capacity = 4. *. mib;
    now = 0.;
    sent = 0.;
    queue = 0.;
    competitor = 0.;
    answer_queue = 0.;
    epoch = "a";
    offset = 1000.;
    stamping;
  }

let base = 0.03

let second s =
  let own = L.rate s.law in
  let offered = own +. s.competitor in
  let drained = Float.min s.capacity (offered +. s.queue) in
  s.queue <-
    Float.min (0.25 *. s.capacity)
      (Float.max 0. (s.queue +. offered -. s.capacity));
  s.sent <- s.sent +. (drained *. own /. offered);
  s.now <- s.now +. 1.

let tick s =
  second s;
  second s;
  L.completed s.law ~now:s.now s.sent ~elapsed:2.;
  s.sent <- 0.;
  let request = s.queue /. s.capacity in
  L.observe_delay s.law (`Round_trip "gcs") (base +. request +. s.answer_queue);
  if s.stamping then (
    L.observe_delay s.law (`Round_trip "nas") (base +. request +. s.answer_queue);
    L.observe_delay s.law
      (`One_way ("nas", s.epoch))
      (s.offset +. (base /. 2.) +. request));
  L.tick s.law ~now:s.now ~limited:true ~busy:true

let run s secs =
  for _ = 1 to int_of_float (secs /. 2.) do
    tick s
  done

let mbs r = Printf.sprintf "%.2f MiB/s" (r /. mib)
let capacity s = Option.value ~default:0. (L.capacity s.law)

(* [disturb] acts on one of two identical links after a minute; the other is
   the control. *)
let against_control ~stamping ~secs disturb =
  let s = sim ~stamping () and control = sim ~stamping () in
  run s 60.;
  run control 60.;
  disturb s;
  run s secs;
  run control secs;
  p "  rate %s, control %s: holds %b"
    (mbs (L.rate s.law))
    (mbs (L.rate control.law))
    (L.rate s.law >= 0.9 *. L.rate control.law);
  p "  capacity kept: %b" (capacity s >= 0.9 *. capacity control);
  s

let download s = s.answer_queue <- 0.1

let () =
  p "== a download queues 100 ms of answers, with a stamping store";
  ignore (against_control ~stamping:true ~secs:120. download);
  p "== the same with round-trip stores only";
  ignore (against_control ~stamping:false ~secs:120. download);

  p "== a competitor takes half of the upload direction, with a stamping store";
  let s = sim ~stamping:true () in
  run s 60.;
  s.competitor <- 2. *. mib;
  run s 40.;
  p "  yields to its share: %s (%b)"
    (mbs (L.rate s.law))
    (L.rate s.law < 2. *. mib);

  p "== the far end restarts during a download, its clock origin 5 s later";
  p "  within the new epoch's first window:";
  let restart s =
    download s;
    s.epoch <- "b";
    s.offset <- s.offset +. 5.
  in
  ignore (against_control ~stamping:true ~secs:120. restart);
  p "  after it:";
  let s = against_control ~stamping:true ~secs:1500. restart in
  p "  base delay from round trips only: %.0f ms"
    (Option.get (L.base_delay s.law) *. 1000.);

  p "== the sender sleeps 8 h, then a download starts";
  let sleep s =
    s.offset <- s.offset +. 28800.;
    download s
  in
  ignore (against_control ~stamping:true ~secs:1500. sleep);

  p "== the far end restarts while a competitor holds a queue";
  let s = sim ~stamping:true () in
  run s 60.;
  s.competitor <- 2. *. mib;
  run s 20.;
  s.epoch <- "b";
  s.offset <- s.offset +. 5.;
  run s 40.;
  p "  yields to its share: %s (%b)"
    (mbs (L.rate s.law))
    (L.rate s.law < 2. *. mib)
