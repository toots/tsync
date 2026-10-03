(* Spec 01 §6.5: with every slot for may-block work held by calls that do not
   return, non-blocking and time-sensitive work still runs, and may-block work
   does not. A watchdog turns a wedge into a line of output. *)

open Tsync_core
module Ipc = Tsync_ipc.Ipc

let checks = ref 0

let check name b =
  incr checks;
  Printf.printf "%s %s\n%!" (if b then "ok  " else "FAIL") name

(* More than the runtime has slots, whatever the number of domains. *)
let pinners = 300

let () =
  ignore
    (Thread.create
       (fun () ->
         Thread.delay 30.;
         Printf.printf "wedged\n%!";
         exit 2)
       ());
  let hold, release = Unix.pipe () in
  let released = Atomic.make 0 in
  let dir = Filename.temp_dir "tsync-class" "" in
  Unix.chmod dir 0o700;
  let socket = Filename.concat dir "s" in
  let action a = `Assoc [("action", `String a)] in
  Rt.run_sync (fun () ->
      Rt.within `Direct (fun () ->
          let handled = Atomic.make 0 in
          let server =
            Ipc.serve ~path:socket (fun _ ->
                Atomic.incr handled;
                Ipc.Reply (Ipc.ok []))
          in
          for _ = 1 to pinners do
            Rt.spawn (fun () ->
                ignore (Unix.read hold (Bytes.create 1) 0 1);
                Atomic.incr released)
          done;
          Rt.sleep 0.5;
          let may_block_ran = Rt.Promise.create () in
          Rt.spawn (fun () -> Rt.Promise.resolve may_block_ran ());
          Rt.sleep 0.1;
          check "a sleep ends" true;
          check "a timeout fires"
            (try
               Rt.with_timeout 0.05 (fun () -> Rt.sleep 10.);
               false
             with Rt.Timeout -> true);
          let fired = Rt.Promise.create () in
          Rt.timer ~execution:`Direct 0.01 (fun () ->
              Rt.Promise.resolve fired ());
          Rt.Promise.await fired;
          check "a time-sensitive timer fires" true;
          let a, b = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
          Unix.set_nonblock a;
          let echoed =
            Rt.async (fun () ->
                Rt.within `Immediate (fun () ->
                    Rt.wait_readable a;
                    let buf = Bytes.create 4 in
                    Bytes.sub_string buf 0 (Unix.read a buf 0 4)))
          in
          Rt.sleep 0.05;
          ignore (Unix.write_substring b "ping" 0 4);
          check "a non-blocking socket read completes"
            (Rt.Promise.await echoed = "ping");
          Unix.close a;
          Unix.close b;
          let gate = Rt.Promise.create () in
          let waited =
            Rt.async (fun () ->
                Rt.within `Immediate (fun () -> Rt.Promise.await gate))
          in
          Rt.sleep 0.05;
          Rt.Promise.resolve gate 7;
          check "a wait inside non-blocking work resumes"
            (Rt.Promise.await waited = 7);
          let started = Rt.Promise.create () in
          Rt.spawn ~execution:`Immediate (fun () ->
              Rt.Promise.resolve started ());
          Rt.Promise.await started;
          check "a fiber spawned as non-blocking starts" true;
          check "a liveness probe is answered"
            (Ipc.call ~timeout:5. socket (action "ping") = Ipc.ok []);
          let asked = Rt.async (fun () -> Ipc.call socket (action "other")) in
          Rt.sleep 0.2;
          check "a request to the handler waits for a slot"
            (Atomic.get handled = 0 && not (Rt.Promise.is_resolved asked));
          check "no pinned call has returned" (Atomic.get released = 0);
          check "may-block work has not run"
            (not (Rt.Promise.is_resolved may_block_ran));
          ignore (Unix.write release (Bytes.make pinners 'x') 0 pinners);
          Rt.Promise.await may_block_ran;
          check "may-block work runs once slots are released" true;
          check "the handler answers once slots are released"
            (Rt.Promise.await asked = Ipc.ok [] && Atomic.get handled = 1);
          check "leaving for may-block work and coming back"
            (Rt.within `Threaded (fun () -> 1) = 1);
          Rt.within `Threaded (fun () -> Ipc.close server)));
  (try Unix.rmdir dir with Unix.Unix_error _ -> ());
  Printf.printf "%d checks\n" !checks
