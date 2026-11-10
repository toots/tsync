(* ios.md §2: the holder record as the ownership lock. *)

open Tsync_core
module Owner = Tsync_owner.Owner

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-ownership-%d" (Unix.getpid ()))

let d = Domain_name.v "d"
let path () = Tsync_config.Paths.ownership_lock d

let show = function
  | Ok _ -> "acquired"
  | Error (Some (h : Owner.holder)) ->
      Printf.sprintf "refused, held by %s"
        (if h.pid = Pid.self () then "this process" else h.what)
  | Error None -> "refused, no record"

let plant pid what =
  Fs.mkdir_p (Filename.dirname (path ()));
  Fs.replace (path ())
    (Printf.sprintf {|{"pid":%d,"role":"app","what":"%s","socket":null}|} pid
       what)

let () =
  Fs.rm_rf root;
  Unix.putenv "HOME" root;
  Unix.putenv "XDG_DATA_HOME" (Filename.concat root "data");
  Owner.use_records ();
  let acquire () = Owner.acquire ~role:"app" ~what:"this test" d in
  let first = acquire () in
  Printf.printf "free: %s\n" (show first);
  Printf.printf "record: %s\n"
    (match Owner.holder d with Some h -> h.what | None -> "none");
  Printf.printf "again in this process: %s\n" (show (acquire ()));
  (match first with Ok l -> Owner.release l | Error _ -> ());
  Printf.printf "released, record left: %b\n" (Sys.file_exists (path ()));
  let child =
    Unix.create_process "sleep" [| "sleep"; "30" |] Unix.stdin Unix.stdout
      Unix.stderr
  in
  plant child "a live process";
  Printf.printf "held by a live process: %s\n" (show (acquire ()));
  Unix.kill child Sys.sigkill;
  ignore (Unix.waitpid [] child);
  plant child "a dead process";
  let after = acquire () in
  Printf.printf "held by a dead process: %s\n" (show after);
  Printf.printf "record: %s\n"
    (match Owner.holder d with Some h -> h.what | None -> "none");
  (match after with Ok l -> Owner.release l | Error _ -> ());
  Fs.rm_rf root
