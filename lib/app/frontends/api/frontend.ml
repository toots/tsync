type binding = {
  conf : (module Conf_lwt.S);
  options : (string * string) list;
  mount_point : string;
}

type topology = [ `One_process | `Process_per_binding ]

type served = {
  binding : binding;
  domain : (module Domain_engine.Domain);
  peers : string list;
}

type socket = [ `Domain_socket | `Proxy_socket ]

type daemon = {
  topology : topology;
  listens : socket option;
  start : served list -> unit;
}

type serving = Daemon of daemon | Commands of string
type tree = [ `Replicated | `Pulled of string ]

module type S = sig
  (* Where [key]'s bytes are, for `tsync ls` and the item rows. *)
  val availability :
    Conf.locality -> Logical_key.t -> Tsync_checkout.Checkout.availability

  val serving : serving
  val tree : tree
end

type command = {
  verb : string;
  doc : string;
  run : (module Conf_lwt.S) -> string list -> unit;
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
      let module C = (val b.conf : Conf_lwt.S) in
      acc + C.max_uploads + C.max_downloads)
    0 bindings

let cap_blocking_pool ~concurrency =
  use_libev ();
  let n = pool_size concurrency in
  Lwt_unix.set_pool_size n;
  Log.debug "blocking thread pool: at most %d" n

(* All told at once, then waited for together, for as long as a stop may take
   and a little more: a child still there after that is killed, since what it
   owed is on disk and a supervisor would end the whole group the same way,
   only later. *)
let reap child_pids =
  List.iter (fun pid -> try Unix.kill pid Sys.sigterm with _ -> ()) child_pids;
  let deadline = Unix.gettimeofday () +. !Shutdown.grace +. 2. in
  let running pid =
    match Unix.waitpid [Unix.WNOHANG] pid with
      | 0, _ -> true
      | _ -> false
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> true
      | exception Unix.Unix_error _ -> false
  in
  let rec wait left =
    match List.filter running left with
      | [] -> ()
      | left when Unix.gettimeofday () > deadline ->
          List.iter
            (fun pid ->
              Log.warn "frontend %d still running after the stop; killing it"
                pid;
              (try Unix.kill pid Sys.sigkill with _ -> ());
              try ignore (Unix.waitpid [] pid) with _ -> ())
            left
      | left ->
          Unix.sleepf 0.05;
          wait left
  in
  wait child_pids

(* Explicitly in order: [List.map]'s is unspecified, and these are forks. A
   child runs [f] and exits without ever reaching the reaper below, so its
   siblings stay the parent's to signal. *)
let fork_each f items =
  let child_pids =
    List.fold_left
      (fun acc x ->
        let pid = Lwt_unix.fork () in
        if pid = 0 then (
          (* The one place every forked process passes through, and exactly
             once: its uptime is its own, not the parent's. *)
          Diagnostics.restart ();
          f x;
          exit 0);
        pid :: acc)
      [] items
    |> List.rev
  in
  (* Told the moment this process is, not after its own drain: a child that
     forks in turn then stops alongside its children, within one grace, where
     waiting for it to reap them first would take two and outlast the deadline
     its own parent gives it. *)
  let tell_children =
    Shutdown.on_request (fun () ->
        List.iter
          (fun pid -> try Unix.kill pid Sys.sigterm with _ -> ())
          child_pids)
  in
  (* Taken back once they are reaped, so a later stop signals no pid the
     system has since given to something else. *)
  fun () ->
    reap child_pids;
    tell_children ()

let run_forked f items =
  match List.rev items with
    | [] -> ()
    | last :: rest ->
        (* The last item runs here rather than in a child, so its failure would
         otherwise leave every sibling already forked behind it. *)
        let reap = fork_each f (List.rev rest) in
        Fun.protect ~finally:reap (fun () -> f last)
