(* One domain's binding for a frontend: the domain conf, this frontend's options
   (from [frontend_config.options]), and the mount point, which only fuse uses. *)
type binding = {
  conf : (module Conf.S);
  options : (string * string) list;
  mount_point : string;
}

module type S = sig
  (* Whether every byte of [key] is on this machine, for `tsync ls`. *)
  val is_local : Conf.locality -> string -> bool

  (* Blocks until shutdown. *)
  val start : binding list -> unit
end

(* Mirrors Backend.field_spec, so `tsync configure` prompts for a frontend's
   options generically. *)
type field_type = [ `String | `Bool | `Int ]

type field_spec = {
  name : string;
  label : string;
  typ : field_type;
  default : string option;
      (** [None] is required; [Some ""] optional, omitted when blank; [Some s]
          optional with default [s]. *)
  secret : bool;
}

(* A CLI subcommand a frontend contributes, surfaced as [tsync <cli_group>
   <verb>]. Declarative and cmdliner-free, like {!field_spec}: the binary parses
   arguments and resolves [--domain] to a {!Conf.S}, checking this frontend is
   configured for it, before calling [run]. *)
type command = { verb : string; doc : string; run : (module Conf.S) -> unit }

type entry = {
  modl : (module S);
  spec : field_spec list;
  cli_group : string;
  commands : command list;
}

let registry : (string, entry) Hashtbl.t = Hashtbl.create 4

let register ?(spec = []) ?(cli_group = "") ?(commands = []) name
    (m : (module S)) =
  let cli_group = if cli_group = "" then name else cli_group in
  Hashtbl.replace registry name { modl = m; spec; cli_group; commands }

let find name = Option.map (fun e -> e.modl) (Hashtbl.find_opt registry name)

let spec_for name =
  Option.value ~default:[]
    (Option.map (fun e -> e.spec) (Hashtbl.find_opt registry name))

let names () = List.of_seq (Hashtbl.to_seq_keys registry)

(* (frontend name, CLI group, contributed commands) per registered frontend. *)
let entries () =
  Hashtbl.fold
    (fun name e acc -> (name, e.cli_group, e.commands) :: acc)
    registry []

(* Call from inside a leaf's own Lwt loop, after all forking: the first Lwt_unix
   touch creates the notification eventfd, and a child inheriting a shared one
   loses its worker-completion wakeups.

   Lwt's default pool of up to 1000 threads far exceeds this workload, since
   max_uploads and max_downloads already bound real concurrency. The ceiling stays
   generous rather than the per-domain sum because the parallel directory walk
   fans out one detached [stat] per entry. *)
let cap_blocking_pool () = Lwt_unix.set_pool_size 256

(* Narrow that ceiling to what the storage absorbs, once something has asked it.

   The default is a burst ceiling, not a statement about any device: a USB
   enclosure taking one command at a time will exhaust the block layer's queue
   tags long before the threads help. Threads past what the device takes become a
   queue in the wrong place.

   The multiple leaves room for the pool's other work — directory walks, stats,
   metadata that must not queue behind bulk reads — and the floor keeps a slow
   device from making the process unresponsive rather than merely unhurried. *)
let size_blocking_pool ~concurrency =
  Lwt_unix.set_pool_size (min 256 (max 32 (concurrency * 8)))

(* Each item gets its own child process except the last, which runs here and
   blocks, since a frontend's [start] blocks. On return, SIGTERM and reap.

   [Lwt_unix.fork], not [Unix.fork]: Lwt's notification eventfd is created at
   module init, so a plain fork leaves parent and child sharing it and the child's
   worker wakeups go to the wrong process. [Lwt_unix.fork] reinitializes it. *)
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
