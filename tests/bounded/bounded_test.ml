(* The shared bound for fan-outs whose width a caller chooses.

   The failure it prevents is a bound governing the wrong resource: a whole-file
   fetch limited to [max_downloads] downloads while descriptors scaled with the
   file, each pending fetch opening its destination before queueing for a slot.
   So what is asserted is that the body — where resources are taken — never runs
   wider than asked, and that a full queue refuses rather than accumulating. *)

open Lwt.Syntax

let failures = ref 0

let check name ok =
  if ok then Printf.printf "%s: ok\n%!" name
  else begin
    incr failures;
    Printf.printf "%s: FAILED\n%!" name
  end

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
  let+ out = Lwt_bounded.map_with t body (List.init jobs Fun.id) in
  (out, !widest)

let () =
  Lwt_main.run
    (let* out, widest =
       peak (Lwt_bounded.create ~max:4 ()) ~jobs:100 (fun x -> x * 2)
     in
     check "never wider than the bound" (widest <= 4);
     check "as wide as the bound, so it is the bound that capped it" (widest = 4);
     check "every job still ran" (List.length out = 100);
     check "results keep the caller's order"
       (out = List.init 100 (fun i -> i * 2));

     (* A bound wider than the work is not a floor: nothing is invented. *)
     let* _, widest = peak (Lwt_bounded.create ~max:50 ()) ~jobs:3 Fun.id in
     check "a bound above the work does not force width" (widest <= 3);

     (* A nonsense bound must not mean "unbounded": that is the failure mode
        being prevented. *)
     let* _, widest = peak (Lwt_bounded.create ~max:0 ()) ~jobs:20 Fun.id in
     check "a bound of zero serialises rather than unleashes" (widest = 1);

     let* kept =
       Lwt_bounded.filter_map_with
         (Lwt_bounded.create ~max:3 ())
         (fun i -> Lwt.return (if i mod 2 = 0 then Some i else None))
         (List.init 10 Fun.id)
     in
     check "filter_map keeps the right ones, in order" (kept = [0; 2; 4; 6; 8]);

     (* Holding every arrival turns a busy resource into a growing list of
        promises whose callers time out with nothing to say why. *)
     let t = Lwt_bounded.create ~max:2 ~max_waiting:5 () in
     let gate, release = Lwt.wait () in
     let refused = ref 0 in
     let job () =
       Lwt_bounded.use_or t
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

     check "only the limit is running" (Lwt_bounded.in_flight t = 2);
     check "only the queue is waiting" (Lwt_bounded.waiting t = 5);
     check "everyone else is refused, not held" (!refused = 20 - 2 - 5);

     Lwt.wakeup_later release ();
     let* () = Lwt.join all in

     (* A refusal must not consume a slot, or the bound erodes with every
        overload. *)
     check "every slot came back" (Lwt_bounded.in_flight t = 0);
     check "nothing is left queued" (Lwt_bounded.waiting t = 0);

     (* Without a queue limit nobody is ever refused, however deep it gets. *)
     let t = Lwt_bounded.create ~max:2 () in
     let+ (_ : unit list) =
       Lwt_bounded.map_with t (fun _ -> Lwt.pause ()) (List.init 50 Fun.id)
     in
     check "an unbounded queue serves everyone" (Lwt_bounded.in_flight t = 0);
     check "and leaves nothing queued" (Lwt_bounded.waiting t = 0));
  exit (if !failures = 0 then 0 else 1)
