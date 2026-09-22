(* The process governor's line, ticker and probes, on the hand-turned clock.

   The law itself is tested apart; here what is pinned is the plumbing around
   it: who waits and in what order, what passes ahead, what a drop costs, when
   a probe is sent, and that a timeout the drivers counted reaches the law on
   the next step. *)

open Lwt.Syntax
open Check
module U = Uplink.Make (Io_lwt.Core) (Fake_clock)

let mb = 1024 * 1024

let rec settle n =
  if n = 0 then Lwt.return_unit
  else
    let* () = Lwt.pause () in
    settle (n - 1)

let on = { Uplink_control.default_settings with enabled = true }
let landed = ref []

(* A background acquire that notes its tag when it gets through. *)
let ask g tag bytes =
  let+ () = U.acquire g ~class_:Background ~bytes in
  landed := tag :: !landed

let () =
  Uplink_control.initial_rate := float_of_int mb;
  Uplink_control.tick_interval := 2.;
  Uplink_budget.stall_timeout := 60.;
  Uplink_budget.burst_seconds := 2.;
  Lwt_main.run
    (case "waiters wake in order as the budget refills";
     Fake_clock.reset ();
     let g = U.create ~settings:on () in
     let a = ask g "a" mb and b = ask g "b" mb and c = ask g "c" mb in
     let* () = settle 3 in
     check "two seconds of burst pass, the third waits"
       (List.rev !landed = ["a"; "b"] && U.waiting g = 1);
     Fake_clock.advance 1.;
     let* () = Lwt.join [a; b; c] in
     check "a second later, the third" (List.rev !landed = ["a"; "b"; "c"]);
     check "and nothing waits" (U.waiting g = 0);

     case "a small body passes a queued chunk";
     landed := [];
     let chunk = ask g "chunk" mb in
     let* () = settle 3 in
     check "the chunk waits on an empty bucket" (U.waiting g = 1);
     Fake_clock.advance 0.5;
     let* () = ask g "small" 1024 in
     check "half a second on, a kilobyte passes it"
       (!landed = ["small"] && U.waiting g = 1);
     Fake_clock.advance 0.6;
     let* () = chunk in
     check "then the chunk goes" (List.rev !landed = ["small"; "chunk"]);

     case "the drop path: room, or a drop that charges nothing";
     Fake_clock.reset ();
     let g = U.create ~settings:on () in
     check "room on a fresh budget" (U.try_admit g ~bytes:mb);
     (* The whole burst still passes at once: asking took none of it. *)
     let* () = U.acquire g ~class_:Background ~bytes:(2 * mb) in
     check "asking took nothing" (U.waiting g = 0);
     let waiting = ask g "w" mb in
     let* () = settle 3 in
     check "with a line ahead, no room" (not (U.try_admit g ~bytes:1024));
     check "which is a drop" (Uplink_control.drops (U.control g) = 1);
     Fake_clock.advance 3.;
     let* () = waiting in

     case "disabled, everything passes at once";
     let g = U.create ~settings:{ on with enabled = false } () in
     let* () =
       Lwt.join (List.init 10 (fun _ -> U.acquire g ~class_:Background ~bytes:mb))
     in
     check "ten megabytes, no line" (U.waiting g = 0);
     check "and the drop path always has room" (U.try_admit g ~bytes:mb);

     case "a foreground body never waits";
     Fake_clock.reset ();
     let g = U.create ~settings:on () in
     let* () = U.acquire g ~class_:Background ~bytes:(2 * mb) in
     let* () = U.acquire g ~class_:Foreground ~bytes:mb in
     check "through an empty bucket" (U.waiting g = 0);

     case "a body given up on leaves the window";
     Uplink_budget.stall_timeout := 2.;
     Fake_clock.reset ();
     let g = U.create ~settings:on () in
     let adm = U.admission g Background in
     let* () = adm.Uplink.acquire ~bytes:mb in
     let second = adm.Uplink.acquire ~bytes:mb in
     let* () = settle 3 in
     check "the second waits on the window" (adm.Uplink.waiting () = 1);
     adm.Uplink.abandoned ~bytes:mb;
     let* () = second in
     check "and passes once the first is gone" (adm.Uplink.waiting () = 0);
     Uplink_budget.stall_timeout := 60.;

     case "a timeout the drivers counted reaches the law on the next step";
     Fake_clock.reset ();
     let g = U.create ~settings:on () in
     let* () = U.acquire g ~class_:Background ~bytes:1024 in
     let before = Uplink_control.rate (U.control g) in
     Metrics.add_timeout 1;
     Fake_clock.advance 2.;
     let* () = settle 5 in
     check "halved" (Uplink_control.rate (U.control g) = before *. 0.5);
     check "and backing off" (Uplink_control.state (U.control g) = Backing_off);

     case "a probe is sent only while bytes are in flight";
     Fake_clock.reset ();
     let g = U.create ~settings:on () in
     let probed = ref 0 in
     U.attach g ~name:"store"
       ~held:(fun () -> false)
       ~probe:(fun () ->
         incr probed;
         Lwt.return_unit);
     Fake_clock.advance 2.;
     let* () = settle 5 in
     check "idle: none" (!probed = 0);
     let adm = U.admission g Background in
     let* () = adm.Uplink.acquire ~bytes:mb in
     Fake_clock.advance 2.;
     let* () = settle 5 in
     check "a body in flight: one a tick" (!probed = 1);
     adm.Uplink.completed ~bytes:mb ~elapsed:1.;
     Fake_clock.advance 2.;
     let* () = settle 5 in
     check "answered: none again" (!probed = 1);
     let held = ref true in
     U.attach g ~name:"down" ~held:(fun () -> !held) ~probe:(fun () -> incr probed; Lwt.return_unit);
     let* () = adm.Uplink.acquire ~bytes:mb in
     Fake_clock.advance 2.;
     let* () = settle 5 in
     check "a store held down is left alone" (!probed = 2);

     report ~expected:21 ();
     Lwt.return_unit)
