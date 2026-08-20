type binding = {
  conf : (module Conf.S);
  options : (string * string) list;
  mount_point : string;
}

type topology = [ `One_process | `Process_per_binding ]
type served = { binding : binding; domain : (module Domain_engine.Domain) }
type socket = [ `Domain_socket | `Proxy_socket ]

module type S = sig
  (* Whether every byte of [key] is on this machine, for `tsync ls`. *)
  val is_local : Conf.locality -> string -> bool
  val topology : topology
  val listens : socket option

  (* Blocks until shutdown. *)
  val start : served list -> unit
end

type command = {
  verb : string;
  doc : string;
  run : (module Conf.S) -> string list -> unit;
}

type entry = {
  modl : (module S);
  spec : Field_spec.t list;
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

let entries () =
  Hashtbl.fold
    (fun name e acc -> (name, e.cli_group, e.commands) :: acc)
    registry []

let use_libev () =
  if not (Lwt_sys.have `libev) then
    failwith
      "lwt was built without libev support, which tsync requires: select \
       cannot watch descriptors above FD_SETSIZE. Rebuild it with libev \
       available (opam reinstall lwt).";
  Lwt_engine.set (new Lwt_engine.libev ());
  Log.debug "event loop engine: libev"

(* Lwt grows the pool to its ceiling on demand and never gives a thread back, so
   the ceiling is a memory floor once anything has been busy: each thread's
   touched stack costs around half a megabyte, and a mount left at 256 settled at
   ~114MB of anonymous memory, which is the whole budget of a small host.

   The threads serve blocking I/O, so nothing about the machine bounds a useful
   number of them -- more than the storage absorbs is a queue in the wrong place,
   and that figure comes from the domains, never from here. *)
let pool_size concurrency = min 256 (max 32 (concurrency * 8))

(* Summed rather than maxed: the pool is per process while the figures are per
   domain, so a child serving several owes each of them its budget. *)
let binding_concurrency bindings =
  List.fold_left
    (fun acc b ->
      let module C = (val b.conf : Conf.S) in
      acc + C.max_uploads + C.max_downloads)
    0 bindings

(* A frontend that later hears what its storage absorbs sets the size twice.
   Worded apart so the second line reads as the correction it is rather than as
   the first one logged again. *)
let pool_size_set = ref 0

let set_pool_size n =
  Lwt_unix.set_pool_size n;
  pool_size_set := n

let cap_blocking_pool ~concurrency =
  use_libev ();
  let n = pool_size concurrency in
  set_pool_size n;
  Log.debug "blocking thread pool: at most %d" n

let size_blocking_pool ~concurrency =
  let n = pool_size concurrency in
  if n <> !pool_size_set then begin
    set_pool_size n;
    Log.debug "blocking thread pool: narrowed to %d" n
  end

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
