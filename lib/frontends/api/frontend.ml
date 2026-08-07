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

let cap_blocking_pool () =
  use_libev ();
  Lwt_unix.set_pool_size 256

let size_blocking_pool ~concurrency =
  Lwt_unix.set_pool_size (min 256 (max 32 (concurrency * 8)))

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
