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

  case "a stop reaches the children at once, before any reaping";
  Shutdown.reset ();
  (* Every child holds the write end, so the read end sees its end of file
     only once all of them are gone. *)
  let gone, alive = Unix.pipe () in
  let reap = Frontend.fork_each (fun _ -> Unix.sleepf 30.) [1; 2] in
  Unix.close alive;
  Shutdown.request ();
  let ended =
    match Unix.select [gone] [] [] 2. with
      | [], _, _ -> false
      | _ -> Unix.read gone (Bytes.create 1) 0 1 = 0
  in
  check "both ended without being reaped" ended;
  reap ();

  report ~expected:3 ()
