(* A store with a ceiling on what is written to it, per second.

   The gate is built over the hand-turned clock and handed to the real
   {!Backend_lwt.make}, so what is pinned is which body was admitted at which
   second, and that the gate changes nothing about what is counted: the same
   bytes cross, later. The in-flight window is watched with a store that holds
   a body until told to let it go. *)

open Lwt.Syntax
open Check
module Gate = Uplink.Make (Io_lwt.Core) (Fake_clock) (Uplink.Silent)
module Memory = Doubles.Memory
module One = Doubles.Memory ()
module Held = Doubles.Outage (One)

let () =
  Backend_lwt.register ~spec:[] "memory" (fun _ ->
      (module Memory () : Backend_lwt.Store));
  Backend_lwt.register ~spec:[] "held" (fun _ ->
      (module Held : Backend_lwt.Store))

let mb = 1024 * 1024
let body n = Bigstring.of_string (String.make n 'x')
let key i = Stored_key.listed (Printf.sprintf "k%d" i)

let rec settle n =
  if n = 0 then Lwt.return_unit
  else
    let* () = Lwt.pause () in
    settle (n - 1)

let capped ~rate backend_type =
  let admission = Gate.capped ~rate in
  ( Backend_lwt.make ~admission ~backend_type ~get_field:(fun _ -> None) (),
    admission )

(* [n] puts of [size] bytes at once, and a reader of how many have landed. *)
let put_many (module S : Backend_lwt.Store) ~size n =
  let landed = ref 0 in
  let all =
    Lwt.join
      (List.init n (fun i ->
           let+ () = S.put ~key:(key i) ~data:(body size) () in
           incr landed))
  in
  (all, fun () -> !landed)

let () =
  Lwt_main.run
    (Uplink_budget.stall_timeout := 60.;
     Uplink_budget.burst_seconds := 2.;
     Fake_clock.reset ();

     case "ten megabytes at a megabyte a second: two now, one more each second";
     let (module S), gate = capped ~rate:(float_of_int mb) "memory" in
     let before = Metrics.uploaded () in
     let all, landed = put_many (module S) ~size:mb 10 in
     let* () = settle 5 in
     check "two seconds of burst go at once" (landed () = 2);
     check "the rest wait in line" (gate.Uplink.waiting () = 8);
     let seen = ref [] in
     let rec second t =
       if t > 8 then Lwt.return_unit
       else begin
         Fake_clock.advance 1.;
         let* () = settle 5 in
         seen := landed () :: !seen;
         second (t + 1)
       end
     in
     let* () = second 1 in
     let* () = all in
     check "one more each second"
       ~why:(fun () ->
         String.concat "," (List.map string_of_int (List.rev !seen)))
       (List.rev !seen = [3; 4; 5; 6; 7; 8; 9; 10]);
     check "the line is empty" (gate.Uplink.waiting () = 0);
     check "every byte counted, exactly as without a gate"
       (Metrics.uploaded () - before = 10 * mb);

     case "with no ceiling, nothing waits";
     let (module S) =
       Backend_lwt.make ~backend_type:"memory" ~get_field:(fun _ -> None) ()
     in
     let before = Metrics.uploaded () in
     let all, landed = put_many (module S) ~size:mb 10 in
     let* () = all in
     check "all ten at once" (landed () = 10);
     check "and the same bytes" (Metrics.uploaded () - before = 10 * mb);

     case "a body in flight holds the next behind it, by the stall window";
     (* Two seconds of stall at a megabyte a second: a window of one megabyte,
        so a second megabyte may not queue behind the first. *)
     Uplink_budget.stall_timeout := 2.;
     Fake_clock.reset ();
     Held.reset ();
     Held.set_up false;
     let (module S), gate = capped ~rate:(float_of_int mb) "held" in
     let all, landed = put_many (module S) ~size:mb 2 in
     let* () = settle 5 in
     check "the second waits, and never reached the store"
       ~why:(fun () ->
         Printf.sprintf "waiting=%d calls=%d" (gate.Uplink.waiting ())
           (Held.calls ()))
       (gate.Uplink.waiting () = 1 && Held.calls () = 1);
     Held.set_up true;
     let* () = all in
     check "let go, the first lands and the second follows" (landed () = 2);
     check "leaving the line empty" (gate.Uplink.waiting () = 0);
     Uplink_budget.stall_timeout := 60.;

     case "a small body passes ahead of a queued chunk, and costs it its size";
     Fake_clock.reset ();
     let (module S), gate = capped ~rate:(float_of_int mb) "memory" in
     let* () = S.put ~key:(key 0) ~data:(body (2 * mb)) () in
     let chunk = S.put ~key:(key 1) ~data:(body mb) () in
     let* () = settle 5 in
     check "the chunk waits on an empty bucket" (gate.Uplink.waiting () = 1);
     Fake_clock.advance 0.5;
     let* () = S.put ~key:(key 2) ~data:(body 1024) () in
     check "half a second on, a kilobyte passes it" (gate.Uplink.waiting () = 1);
     Fake_clock.advance 0.5;
     let* () = settle 5 in
     check "a second on, the chunk is still that kilobyte short"
       (gate.Uplink.waiting () = 1);
     Fake_clock.advance 0.1;
     let* () = chunk in
     check "and then goes" (gate.Uplink.waiting () = 0);

     report ~expected:14 ();
     Lwt.return_unit)
