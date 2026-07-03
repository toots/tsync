(* Cumulative totals accumulate, and the rolling rate reflects bytes added
   within the current window (sum / window seconds). *)
let () =
  Metrics.add_uploaded 100;
  Metrics.add_uploaded 50;
  Metrics.add_downloaded 30;
  Metrics.add_hashed 3;
  assert (Metrics.uploaded () = 150);
  assert (Metrics.downloaded () = 30);
  assert (Metrics.hashed () = 3);
  (* window is 10s; all adds land in the current window, so rate = total / 10 *)
  assert (Metrics.upload_rate () = 15.0);
  assert (Metrics.download_rate () = 3.0);
  print_endline "metrics_test ok"
