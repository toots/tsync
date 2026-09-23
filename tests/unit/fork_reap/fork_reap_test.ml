(* The reaper a daemon runs over its forked frontends once it has stopped:
   every child told at once, all waited for together, and one that will not go
   killed once a stop's grace is spent, so the daemon's own exit is never held
   past it. *)

open Check

let () =
  Shutdown.grace := 0.2;
  case "children that stop when told are reaped at once";
  let reap =
    Frontend.fork_each
      (fun _ ->
        (* Ends on SIGTERM, the default action. *)
        Unix.sleepf 30.)
      [1; 2; 3]
  in
  let t0 = Unix.gettimeofday () in
  reap ();
  check "well inside the grace" (Unix.gettimeofday () -. t0 < 1.);

  case "one that ignores the stop is killed once the grace is spent";
  let reap =
    Frontend.fork_each
      (fun slow ->
        if slow then Sys.set_signal Sys.sigterm Sys.Signal_ignore;
        Unix.sleepf 30.)
      [false; true]
  in
  (* The child sets its handler after the fork; give it the moment. *)
  Unix.sleepf 0.2;
  let t0 = Unix.gettimeofday () in
  reap ();
  let took = Unix.gettimeofday () -. t0 in
  check "after the grace and its margin, not the child's thirty seconds"
    ~why:(fun () -> Printf.sprintf "%.1fs" took)
    (took >= 2. && took < 5.);

  report ~expected:2 ()
