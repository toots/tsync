open Tsync_core

let checks = ref 0

let check name b =
  incr checks;
  Printf.printf "%s %s\n" (if b then "ok  " else "FAIL") name

let () =
  Rt.run_sync (fun () ->
      let t0 = Rt.now () in
      Rt.sleep 0.05;
      check "sleep" (Rt.now () -. t0 >= 0.05);
      check "timeout"
        (try
           Rt.with_timeout 0.05 (fun () -> Rt.sleep 10.);
           false
         with Rt.Timeout -> true);
      check "first"
        (Rt.first
           [
             (fun () ->
               Rt.sleep 1.;
               1);
             (fun () -> 2);
           ]
        = 2);
      check "all order"
        (Rt.map_concurrently
           (fun i ->
             Rt.sleep (0.01 *. float (5 - i));
             i)
           [1; 2; 3; 4]
        = [1; 2; 3; 4]);
      let m = Rt.Fmutex.create ()
      and inside = Atomic.make 0
      and worst = Atomic.make 0 in
      Rt.iter_concurrently
        (fun _ ->
          Rt.Fmutex.with_lock m (fun () ->
              let n = Atomic.fetch_and_add inside 1 + 1 in
              if n > Atomic.get worst then Atomic.set worst n;
              Rt.yield ();
              Atomic.decr inside))
        (List.init 50 Fun.id);
      check "mutex exclusion" (Atomic.get worst = 1);
      let sem = Rt.Semaphore.create 3
      and cur = Atomic.make 0
      and peak = Atomic.make 0 in
      Rt.iter_concurrently
        (fun _ ->
          Rt.Semaphore.with_slot sem (fun () ->
              let n = Atomic.fetch_and_add cur 1 + 1 in
              if n > Atomic.get peak then Atomic.set peak n;
              Rt.sleep 0.005;
              Atomic.decr cur))
        (List.init 20 Fun.id);
      check "semaphore bound" (Atomic.get peak = 3);
      let p = Rt.Promise.create () in
      Rt.spawn (fun () ->
          Rt.sleep 0.01;
          Rt.Promise.resolve p 42);
      check "promise" (Rt.Promise.await p = 42);
      let finalized = Atomic.make false in
      (try
         Rt.with_timeout 0.02 (fun () ->
             Fun.protect
               ~finally:(fun () -> Atomic.set finalized true)
               (fun () -> Rt.sleep 5.))
       with Rt.Timeout -> ());
      Rt.sleep 0.01;
      check "cancel runs finally" (Atomic.get finalized));
  Printf.printf "%d checks\n" !checks
