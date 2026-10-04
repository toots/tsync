(* 07 §3.1 step 7: whether a supervisor runs is read from its lock, so one too busy
   to answer a ping is never replaced by a second start. *)

open Tsync_core
open Tsync_config

let p fmt = Printf.printf (fmt ^^ "\n%!")
let root = Printf.sprintf "/tmp/tsync-sup-%d" (Unix.getpid ())

let () =
  Fs.rm_rf root;
  List.iter
    (fun d -> Fs.mkdir_p ~perm:0o700 (Filename.concat root d))
    ["home"; "data"; "cache"];
  Unix.putenv "HOME" (Filename.concat root "home");
  Unix.putenv "XDG_DATA_HOME" (Filename.concat root "data");
  Unix.putenv "XDG_CACHE_HOME" (Filename.concat root "cache")

let config =
  Config.of_string
    (Printf.sprintf
       {|{"name":"test","domains":[
  {"name":"d","symlinks":"keep","versioning":true,"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/store"}]}]}|}
       root)

let start () =
  match
    Rt.with_timeout 2. (fun () ->
        Tsync_supervisor.Supervisor.run ~exe:"/bin/false" config [])
  with
    | status -> Printf.sprintf "exit %d" status
    | exception Rt.Timeout -> "serving"

let () =
  Rt.run_sync (fun () ->
      (* A running supervisor that answers nothing: its lock held, no socket. *)
      let held = Fs.lifetime_lock (Paths.supervisor_lock ()) in
      p "the lock taken: %b" (held <> None);
      p "a start beside a supervisor that does not answer: %s" (start ());
      Option.iter Unix.close held;
      p "a start once it is gone: %s" (start ()));
  Fs.rm_rf root
