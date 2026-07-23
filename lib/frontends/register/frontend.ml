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

(* Run [f] on each item, each in its own child process except the last (which
   runs in this process and blocks, since a frontend's [start] blocks). On
   return, SIGTERM and reap the forked children. *)
let run_forked f items =
  let rec go child_pids = function
    | [] -> List.rev child_pids
    | [x] ->
        f x;
        List.rev child_pids
    | x :: rest ->
        let pid = Unix.fork () in
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
