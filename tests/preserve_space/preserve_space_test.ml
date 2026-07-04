(* preserve-space setting round-trips through its state file: absent file
   defaults to 10%, numbers in ]0,100[ are accepted, "off" disables, bad
   values are rejected without changing the state. *)
let () =
  let data_dir = Filename.temp_file "tsync_preserve" "" in
  Sys.remove data_dir;
  Unix.mkdir data_dir 0o700;
  let percent () = Ipc.preserve_space_percent ~data_dir in
  let handle = Ipc.handle_preserve_space ~data_dir in
  assert (percent () = Some 10.);
  assert (handle "status" = "10%");
  assert (handle "25" = "25%");
  assert (percent () = Some 25.);
  assert (handle "off" = "off");
  assert (percent () = None);
  assert (handle "0" = "ERROR expected a percentage in ]0,100[, off or status");
  assert (handle "150" = handle "0");
  assert (handle "nope" = handle "0");
  assert (percent () = None);
  assert (handle "7.5" = "7.5%");
  assert (percent () = Some 7.5);
  assert (Disk_space.free_fraction data_dir > 0.);
  assert (Disk_space.free_fraction data_dir < 1.);
  print_endline "preserve_space_test ok"
