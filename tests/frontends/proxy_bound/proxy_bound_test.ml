(* The limit on how much object data http-proxy serves at once.

   Unbounded, an inbound burst becomes that many concurrent reads of the storage
   under the process, and one client opening one large file produces the burst by
   asking for many ranges at once. Past what the device absorbs that is not
   throughput: on a USB-backed store the block layer ran out of queue tags while
   ~96 threads waited and the disk went no faster.

   What has to hold is the bound itself — never more than N data requests in
   flight — and that metadata stays outside it, a listing costing nothing and not
   belonging behind a transfer.

   No sleeps: each job parks on a promise this test resolves, so concurrency is
   controlled rather than raced for. *)

open Lwt.Syntax

let failures = ref 0

let check name ok =
  if ok then Printf.printf "%s: ok\n%!" name
  else begin
    incr failures;
    Printf.printf "%s: FAILED\n%!" name
  end

let limit = 4

(* Each job parks until released. Reports how many ran together, how many were
   admitted, and how many the full queue turned away. *)
let peak_concurrency ~kind ~jobs =
  let running = ref 0 and peak = ref 0 in
  let gate, release = Lwt.wait () in
  let started = ref 0 and refused = ref 0 in
  let job () =
    Http_proxy_frontend.bounded kind
      ~busy:(fun () ->
        incr refused;
        Lwt.return_unit)
      (fun () ->
        incr started;
        incr running;
        if !running > !peak then peak := !running;
        let+ () = gate in
        decr running)
  in
  let all = List.map (fun _ -> job ()) (List.init jobs (fun i -> i)) in
  (* Everything that can start must start before anything finishes, or a job
     frees its slot before the next asks for it and the peak says nothing. *)
  let* () =
    let rec settle n =
      if n = 0 then Lwt.return_unit
      else
        let* () = Lwt.pause () in
        settle (n - 1)
    in
    settle 20
  in
  let admitted = !started in
  Lwt.wakeup_later release ();
  let+ () = Lwt.join all in
  (admitted, !peak, !refused)

let () =
  Lwt_main.run
    (Http_proxy_frontend.gate := Some (Http_proxy_frontend.make_gate limit);

     let* admitted, peak, _ = peak_concurrency ~kind:`Get ~jobs:32 in
     check "no more reads run at once than the limit" (peak <= limit);
     check "the limit is actually reached, so the bound is what capped it"
       (peak = limit);
     check "the rest were held, not rejected" (admitted = limit);

     (* One device underneath, so a write costs what a read costs. *)
     let* _, peak, _ = peak_concurrency ~kind:`Put ~jobs:32 in
     check "writes are bounded too" (peak <= limit);

     let* admitted, peak, _ = peak_concurrency ~kind:`Meta ~jobs:32 in
     check "metadata is not held behind data" (admitted = 32 && peak = 32);

     (* A slot leaked on one request shrinks the bound until the frontend serves
        nothing — a failure that only shows up under load, hours in. *)
     let* _, peak, _ = peak_concurrency ~kind:`Get ~jobs:32 in
     check "the same budget is available afterwards" (peak = limit);

     (* Holding every arrival turns a busy device into a growing list of promises
        whose callers time out with nothing to say why. Refusing is what tells
        them to slow down: every client retries 5xx with backoff. *)
     let queue_limit = limit * 16 in
     let flood = limit + queue_limit + 25 in
     let* admitted, peak, refused = peak_concurrency ~kind:`Get ~jobs:flood in
     check "the bound still holds under a flood" (peak = limit);
     check "the queue holds exactly its limit"
       (admitted = limit && refused = flood - limit - queue_limit);
     check "nothing is silently dropped"
       (admitted + refused + queue_limit = flood);

     (* A refusal must not consume a slot, or the bound erodes with every
        overload. *)
     let* _, peak, refused = peak_concurrency ~kind:`Get ~jobs:32 in
     check "the budget survives a flood" (peak = limit);
     check "a quiet period refuses nobody" (refused = 0);

     (* Lowest wins, or the bound does not bind. *)
     let resolve = Http_proxy_frontend.lowest in
     check "the slowest backend sets the bound"
       (resolve [Some 32; Some 4; Some 16] = Some 4);
     check "backends with no opinion are ignored, not counted as zero"
       (resolve [None; Some 8; None] = Some 8);
     check "no opinion anywhere leaves it to the default"
       (resolve [None; None] = None);
     check "a single backend speaks for itself" (resolve [Some 4] = Some 4);

     Http_proxy_frontend.gate := None;
     let+ admitted, _, _ = peak_concurrency ~kind:`Get ~jobs:8 in
     check "an unconfigured bound lets everything through" (admitted = 8));
  exit (if !failures = 0 then 0 else 1)
