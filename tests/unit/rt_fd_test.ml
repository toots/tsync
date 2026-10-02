(* Waits whose descriptor is closed under them: the scheduler neither exits nor
   wedges. A watchdog turns a wedge into a line of output. *)

open Tsync_core

let p fmt = Printf.printf fmt

let () =
  ignore
    (Thread.create
       (fun () ->
         Thread.delay 20.;
         p "wedged\n%!";
         exit 2)
       ());
  Rt.run_sync (fun () ->
      let a, b = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      let wait () =
        try Rt.wait_readable ~timeout:0.3 a with Rt.Timeout -> ()
      in
      Rt.spawn wait;
      Rt.spawn wait;
      Rt.sleep 0.05;
      Unix.close a;
      Unix.close b;
      Rt.sleep 1.;
      p "two waits outliving their descriptor: the scheduler runs on\n%!";
      let c, d = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      Unix.close c;
      Unix.close d;
      p "a wait on a closed descriptor: %s\n%!"
        (match Rt.with_timeout 2. (fun () -> Rt.wait_readable c) with
          | () -> "returns at once"
          | exception Rt.Timeout -> "timed out"
          | exception e -> Printexc.to_string e);
      Rt.sleep 0.05;
      p "a sleep after it completes\n%!")
