(* The FUSE mount point is its parent resolved through links (fuse §2.1); only
   the FUSE frontend asks, so only Linux checks it. *)

open Tsync_core

let p fmt = Printf.printf fmt

let () =
  p "== a mount point, its parent resolved\n";
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-mnt-%d" (Pid.self ()))
  in
  Fs.rm_rf dir;
  Fs.mkdir_p (Filename.concat dir "real");
  Unix.symlink (Filename.concat dir "real") (Filename.concat dir "link");
  let expected = Filename.concat (Unix.realpath dir) "real/Drive" in
  List.iter
    (fun given ->
      p "%-24s %b\n" given
        (Fs.resolve_parent (Filename.concat dir given) = expected))
    ["real/Drive"; "real/Drive/"; "real/./Drive"; "real//Drive"; "link/Drive"];
  p "%-24s %s\n" "/" (Fs.resolve_parent "/");
  Fs.rm_rf dir
