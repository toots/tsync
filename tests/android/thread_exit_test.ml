(* android §4.3: calls each from a new thread that ends keep the process's
   memory flat. *)

external calls_on_ended_threads : int -> int
  = "tsync_test_calls_on_ended_threads"

let calls = 1000
let mib n = float_of_int n /. 1048576.

let () =
  Tsync_android_bridge.Android_bridge.started ();
  ignore (calls_on_ended_threads 50);
  let before = (Tsync_core.Usage.sample ()).private_ in
  let failures = calls_on_ended_threads calls in
  let grown = (Tsync_core.Usage.sample ()).private_ - before in
  Printf.printf "%d calls on ended threads: %d failed to run\n" calls failures;
  Printf.printf "private memory grew under 8 MiB: %b\n" (grown < 8 lsl 20);
  if grown >= 8 lsl 20 then Printf.eprintf "grew %.1f MiB\n" (mib grown)
