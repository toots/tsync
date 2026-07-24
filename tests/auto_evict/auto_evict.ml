(* Snapshot of per-domain auto-evict: the marker is scoped to the domain name, so
   toggling one domain never affects another. Dumps the observable result of each
   handle_auto_evict / auto_evict_enabled call for a golden-file diff. *)

let () =
  let data_dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      ("tsync-ae-" ^ string_of_int (Unix.getpid ()))
  in
  (try Unix.mkdir data_dir 0o700
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let act d a =
    Printf.printf "[%s] %s = %s\n" d a
      (Ipc.handle_auto_evict ~data_dir ~domain:d a)
  in
  let enabled d =
    Printf.printf "[%s] enabled = %b\n" d
      (Ipc.auto_evict_enabled ~data_dir ~domain:d)
  in
  print_endline "-- initial --";
  enabled "A";
  act "A" "status";
  print_endline "-- enable A only --";
  act "A" "on";
  enabled "A";
  enabled "B";
  act "A" "status";
  act "B" "status";
  print_endline "-- enable B independently --";
  act "B" "on";
  enabled "A";
  enabled "B";
  print_endline "-- disable A, B stays on --";
  act "A" "off";
  enabled "A";
  enabled "B";
  print_endline "-- real names with spaces/apostrophes stay isolated --";
  act "Jellyfin Media" "on";
  enabled "Jellyfin Media";
  enabled "Romain's Files";
  print_endline "-- invalid state --";
  act "A" "bogus"
