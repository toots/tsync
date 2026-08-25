(* The shared bound for fan-outs whose width a caller chooses.

   The failure it prevents is a bound governing the wrong resource: a whole-file
   fetch limited to [max_downloads] downloads while descriptors scaled with the
   file, each pending fetch opening its destination before queueing for a slot.
   So what is asserted is that the body — where resources are taken — never runs
   wider than asked, and that a full queue refuses rather than accumulating. *)

open Lwt.Syntax
open Check

(* Runs [jobs] through [t], recording how wide the bodies ever ran. *)
let peak t ~jobs f =
  let running = ref 0 and widest = ref 0 in
  let body x =
    incr running;
    if !running > !widest then widest := !running;
    let* () = Lwt.pause () in
    let+ () = Lwt.pause () in
    decr running;
    f x
  in
  let+ out = Io_lwt.Bounded.map_with t body (List.init jobs Fun.id) in
  (out, !widest)

let () =
  Lwt_main.run
    (let* out, widest =
       peak (Io_lwt.Bounded.create ~max:4 ()) ~jobs:100 (fun x -> x * 2)
     in
     check "never wider than the bound" (widest <= 4);
     check "as wide as the bound, so it is the bound that capped it" (widest = 4);
     check "every job still ran" (List.length out = 100);
     check "results keep the caller's order"
       (out = List.init 100 (fun i -> i * 2));

     (* A bound wider than the work is not a floor: nothing is invented. *)
     let* _, widest = peak (Io_lwt.Bounded.create ~max:50 ()) ~jobs:3 Fun.id in
     check "a bound above the work does not force width" (widest <= 3);

     (* A nonsense bound must not mean "unbounded": that is the failure mode
        being prevented. *)
     let* _, widest = peak (Io_lwt.Bounded.create ~max:0 ()) ~jobs:20 Fun.id in
     check "a bound of zero serialises rather than unleashes" (widest = 1);

     let* kept =
       Io_lwt.Bounded.filter_map_with
         (Io_lwt.Bounded.create ~max:3 ())
         (fun i -> Lwt.return (if i mod 2 = 0 then Some i else None))
         (List.init 10 Fun.id)
     in
     check "filter_map keeps the right ones, in order" (kept = [0; 2; 4; 6; 8]);

     (* Holding every arrival turns a busy resource into a growing list of
        promises whose callers time out with nothing to say why. *)
     let t = Io_lwt.Bounded.create ~max:2 ~max_waiting:5 () in
     let gate, release = Lwt.wait () in
     let refused = ref 0 in
     let job () =
       Io_lwt.Bounded.use_or t
         ~busy:(fun () ->
           incr refused;
           Lwt.return_unit)
         (fun () -> gate)
     in
     let all = List.init 20 (fun _ -> job ()) in
     let rec settle n =
       if n = 0 then Lwt.return_unit
       else
         let* () = Lwt.pause () in
         settle (n - 1)
     in
     let* () = settle 20 in

     check "only the limit is running" (Io_lwt.Bounded.in_flight t = 2);
     check "only the queue is waiting" (Io_lwt.Bounded.waiting t = 5);
     check "everyone else is refused, not held" (!refused = 20 - 2 - 5);

     Lwt.wakeup_later release ();
     let* () = Lwt.join all in

     (* A refusal must not consume a slot, or the bound erodes with every
        overload. *)
     check "every slot came back" (Io_lwt.Bounded.in_flight t = 0);
     check "nothing is left queued" (Io_lwt.Bounded.waiting t = 0);

     (* Without a queue limit nobody is ever refused, however deep it gets. *)
     let t = Io_lwt.Bounded.create ~max:2 () in
     let* (_ : unit list) =
       Io_lwt.Bounded.map_with t (fun _ -> Lwt.pause ()) (List.init 50 Fun.id)
     in
     check "an unbounded queue serves everyone" (Io_lwt.Bounded.in_flight t = 0);
     check "and leaves nothing queued" (Io_lwt.Bounded.waiting t = 0);

     (* A pool says how wide it is, so a caller running its own workers takes
        the number from the bound rather than restating it. *)
     check "a pool reports what it admits"
       (Io_lwt.Bounded.width (Io_lwt.Bounded.create ~max:7 ()) = 7);
     check "and reports the clamp, not the nonsense it was given"
       (Io_lwt.Bounded.width (Io_lwt.Bounded.create ~max:0 ()) = 1);

     (* [each] is for a fan-out whose length is its own idea, so what is
        asserted is the width alone: it holds no slot and keeps no results. *)
     let running = ref 0 and widest = ref 0 and done_ = ref 0 in
     let taken = ref 0 in
     let next () =
       if !taken >= 100 then None
       else (
         incr taken;
         Some
           (fun () ->
             incr running;
             if !running > !widest then widest := !running;
             let* () = Lwt.pause () in
             let+ () = Lwt.pause () in
             decr running;
             incr done_))
     in
     let* () = Io_lwt.Bounded.each ~width:4 next in
     check "never wider than the workers asked for" (!widest <= 4);
     check "as wide as they were asked for" (!widest = 4);
     check "every job ran" (!done_ = 100);

     (* A source shorter than the workers must not leave one spinning. *)
     let taken = ref 0 in
     let* () =
       Io_lwt.Bounded.each ~width:8 (fun () ->
           if !taken >= 3 then None
           else (
             incr taken;
             Some (fun () -> Lwt.pause ())))
     in
     check "a drained source ends every worker" (!taken = 3);

     (* Draining the rest after a failure would go on reading a file the
        caller has already given up on. *)
     let taken = ref 0 and ran = ref 0 in
     let boom = Failure "boom" in
     let+ raised =
       Lwt.catch
         (fun () ->
           let+ () =
             Io_lwt.Bounded.each ~width:2 (fun () ->
                 if !taken >= 50 then None
                 else (
                   incr taken;
                   let i = !taken in
                   Some
                     (fun () ->
                       incr ran;
                       let* () = Lwt.pause () in
                       if i = 3 then raise boom else Lwt.return_unit)))
           in
           None)
         (fun exn -> Lwt.return_some exn)
     in
     check "the failure reaches the caller" (raised = Some boom);
     check "and stops the workers taking more"
       ~why:(fun () -> Printf.sprintf "%d taken, %d ran" !taken !ran)
       (!taken < 50))
