(* A stop, and what gives way to it: a sleep, and the retry ladder that
   sleeps between tries. On the hand-turned clock, so "at once" means before
   the clock moved at all. *)

open Lwt.Syntax
open Check
module Nap = Shutdown.Sleep (Io_lwt.Core) (Fake_clock)
module R = Retry.Make (Io_lwt.Core) (Fake_clock)

let rec settle n =
  if n = 0 then Lwt.return_unit
  else
    let* () = Lwt.pause () in
    settle (n - 1)

let state p =
  match Lwt.state p with
    | Lwt.Return `Slept -> "slept"
    | Lwt.Return `Stopping -> "stopping"
    | Lwt.Fail exn -> Printexc.to_string exn
    | Lwt.Sleep -> "waiting"

let () =
  Lwt_main.run
    (case "a sleep runs its length with no stop";
     Fake_clock.reset ();
     Shutdown.reset ();
     let p = Nap.sleep 5. in
     Fake_clock.advance 5.;
     let* () = settle 3 in
     check "slept" (state p = "slept");

     case "and ends the moment a stop is asked";
     let p = Nap.sleep 300. in
     let* () = settle 3 in
     check "waiting until then" (state p = "waiting");
     Shutdown.request ();
     let* () = settle 3 in
     check "stopping, the clock not moved" (state p = "stopping");
     check "a sleep begun after the stop does not begin"
       (state (Nap.sleep 300.) = "stopping");

     case "a hook runs once, and not after it is taken back";
     Shutdown.reset ();
     let ran = ref 0 and kept = ref 0 in
     let off = Shutdown.on_request (fun () -> incr ran) in
     let (_ : unit -> unit) = Shutdown.on_request (fun () -> incr kept) in
     off ();
     Shutdown.request ();
     Shutdown.request ();
     check "the one taken back never ran" (!ran = 0);
     check "the other ran once" (!kept = 1);
     let late = ref 0 in
     let (_ : unit -> unit) = Shutdown.on_request (fun () -> incr late) in
     check "one registered after the stop runs at once" (!late = 1);

     case "a retry ladder is not climbed past a stop";
     Shutdown.reset ();
     let tries = ref 0 in
     let failures = Metrics.failures () in
     let ladder =
       Lwt.catch
         (fun () ->
           R.with_retry ~classify:Retry.classify ~name:"store" ~op:"put"
             (fun () ->
               incr tries;
               Lwt.fail (Failure "link down")))
         (fun exn -> Lwt.return (Printexc.to_string exn))
     in
     let* () = settle 5 in
     check "one try, then waiting out the backoff" (!tries = 1);
     Shutdown.request ();
     let* outcome = ladder in
     check "gives up for the stop"
       ~why:(fun () -> outcome)
       (outcome = Printexc.to_string Shutdown.Stopping);
     check "without another try" (!tries = 1);
     check "and counts no failure" (Metrics.failures () = failures);

     report ~expected:11 ();
     Lwt.return_unit)
