(* Pitfall B-12.11: a store's deferred work (Composite.settle_later) may still
   write under a test's scratch root while the test removes it. ponytail:
   retried; a stop for that deferred work would end the race for every test. *)
let remove_root root =
  let rec remove n =
    try Tsync_core.Fs.rm_rf root
    with _ when n > 0 ->
      Unix.sleepf 0.2;
      remove (n - 1)
  in
  remove 10
