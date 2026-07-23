(* One domain's binding for a frontend: the domain conf, this frontend's own
   options (from [frontend_config.options]), and the mount point (fuse uses it;
   others ignore). *)
type binding = {
  conf : (module Conf.S);
  options : (string * string) list;
  mount_point : string;
}

module type S = sig
  val is_local :
    cache_root:string ->
    domain_name:string ->
    domain_prefix:string ->
    string ->
    bool

  (* Run this frontend for all the domains bound to it. Blocks until shutdown. *)
  val start : binding list -> unit
end

let registry : (string, (module S)) Hashtbl.t = Hashtbl.create 4
let register name (m : (module S)) = Hashtbl.replace registry name m
let find name = Hashtbl.find_opt registry name
let names () = List.of_seq (Hashtbl.to_seq_keys registry)

(* Cap the Lwt blocking-syscall thread pool for this process. Call it from inside
   a leaf's own Lwt loop, after all forking is done: the first Lwt_unix touch
   creates the notification eventfd, and if that happens before a fork the child
   inherits a shared eventfd and loses its worker-completion wakeups.

   Lwt's default pool (up to 1000 threads) far exceeds this workload — max_uploads
   and max_downloads already bound real concurrency — but the parallel directory
   walk fans out one detached [stat] per entry, so keep a generous ceiling rather
   than the tiny per-domain sum. 256 covers realistic bursts without letting an
   oversized config (maxDownloads has been seen at 1000) reopen the unbounded pool. *)
let cap_blocking_pool () = Lwt_unix.set_pool_size 256

(* Run [f] on each item, each in its own child process except the last (which
   runs in this process and blocks, since a frontend's [start] blocks). On
   return, SIGTERM and reap the forked children.

   [Lwt_unix.fork] (not [Unix.fork]): Lwt's notification eventfd is created at
   module init, so a plain fork leaves parent and child sharing it — the child's
   worker-completion wakeups then get delivered to the wrong process and its event
   loop hangs. [Lwt_unix.fork] reinitializes that state in the child. *)
let run_forked f items =
  let rec go child_pids = function
    | [] -> List.rev child_pids
    | [x] ->
        f x;
        List.rev child_pids
    | x :: rest ->
        let pid = Lwt_unix.fork () in
        if pid = 0 then (
          f x;
          exit 0);
        go (pid :: child_pids) rest
  in
  let child_pids = go [] items in
  List.iter
    (fun pid ->
      (try Unix.kill pid Sys.sigterm with _ -> ());
      try ignore (Unix.waitpid [] pid) with _ -> ())
    child_pids
