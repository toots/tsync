(* The hand-turned clock, before anything is built on it.

   What is asserted is the one property a controller test will lean on: a sleep
   is over exactly when the clock says so, neither before its deadline nor,
   once cancelled, ever. The stall timeout is checked for the same reason,
   since what it measures is silence rather than elapsed time. *)

open Lwt.Syntax
open Check

(* Wakers run on later scheduler turns; a couple of pauses lets them. *)
let rec settle n =
  if n = 0 then Lwt.return_unit
  else
    let* () = Lwt.pause () in
    settle (n - 1)

let resolved p = not (Lwt.is_sleeping p)

let () =
  Lwt_main.run
    (case "a sleep is over when the clock reaches its deadline";
     let slept = Fake_clock.sleep 5. in
     let* () = settle 3 in
     check "not before" (not (resolved slept));
     Fake_clock.advance 4.;
     let* () = settle 3 in
     check "not at four of five" (not (resolved slept));
     Fake_clock.advance 1.;
     let* () = settle 3 in
     check "at five" (resolved slept);
     check "now reads the time advanced" (Fake_clock.now () = 5.);

     case "two sleeps wake in deadline order, whatever order they were asked";
     let order = ref [] in
     let note tag p = Lwt.map (fun () -> order := tag :: !order) p in
     let long = note "long" (Fake_clock.sleep 3.) in
     let short = note "short" (Fake_clock.sleep 1.) in
     Fake_clock.advance 3.;
     let* () = Lwt.join [long; short] in
     check "short before long" (List.rev !order = ["short"; "long"]);

     case "a timeout fires when its length has passed, not earlier";
     let never, _ = Lwt.wait () in
     let timed = Fake_clock.with_timeout 2. (fun () -> never) in
     Fake_clock.advance 1.9;
     let* () = settle 3 in
     check "still waiting just short of it" (not (resolved timed));
     Fake_clock.advance 0.1;
     let* outcome =
       Lwt.catch
         (fun () -> Lwt.map (fun () -> `Done) timed)
         (fun exn -> Lwt.return (`Failed exn))
     in
     check "then it is the scheduler's own timeout"
       (match outcome with
         | `Failed exn -> Fake_clock.is_timeout exn
         | `Done -> false);

     case "a sleep the winner cancels is not counted, and never wakes";
     let before = Fake_clock.pending () in
     let* answer = Fake_clock.with_timeout 10. (fun () -> Lwt.return 42) in
     let* () = settle 3 in
     check "the body's answer comes back" (answer = 42);
     check "its timer is gone" (Fake_clock.pending () = before);

     case "a stall timeout measures silence, not length";
     (* From a fresh origin, so the instants below read as written. *)
     Fake_clock.reset ();
     let heard_at = ref [] in
     let body alive =
       (* Speaks at 1.5 and again at 3.0, then falls silent. *)
       let* () = Fake_clock.sleep 1.5 in
       alive ();
       heard_at := Fake_clock.now () :: !heard_at;
       let* () = Fake_clock.sleep 1.5 in
       alive ();
       heard_at := Fake_clock.now () :: !heard_at;
       let never, _ = Lwt.wait () in
       never
     in
     let stalled = Fake_clock.with_stall_timeout 2. body in
     Fake_clock.advance 1.5;
     let* () = settle 3 in
     Fake_clock.advance 1.5;
     let* () = settle 3 in
     check "three seconds in, heard at 1.5 and 3.0"
       ~why:(fun () ->
         String.concat ", " (List.map string_of_float (List.rev !heard_at)))
       (List.rev !heard_at = [1.5; 3.0]);
     check "and still running"
       ~why:(fun () ->
         Printf.sprintf "resolved=%b pending=%d now=%g" (resolved stalled)
           (Fake_clock.pending ()) (Fake_clock.now ()))
       (not (resolved stalled));
     Fake_clock.advance 1.9;
     let* () = settle 3 in
     check "silent for under its length, still running" (not (resolved stalled));
     Fake_clock.advance 0.1;
     let* outcome =
       Lwt.catch
         (fun () -> Lwt.map (fun () -> `Done) stalled)
         (fun exn -> Lwt.return (`Failed exn))
     in
     check "two seconds after its last word, given up on"
       (match outcome with
         | `Failed exn -> Fake_clock.is_timeout exn
         | `Done -> false);

     case "reset starts over";
     Fake_clock.reset ();
     check "at zero" (Fake_clock.now () = 0.);
     check "with nothing waiting" (Fake_clock.pending () = 0);

     report ~expected:15 ();
     Lwt.return_unit)
