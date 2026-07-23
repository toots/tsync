(* One domain's binding for a frontend: the domain conf, this frontend's own
   options (from [frontend_config.options]), the domain's backends as
   [(name, backend_type)] aligned with [C.backends] order (for resolving options
   that name a backend), and the mount point (fuse uses it; others ignore). *)
type binding = {
  conf : (module Conf.S);
  options : (string * string) list;
  backend_meta : (string * string) list;
  mount_point : string;
}

module type S = sig
  val implementation : string

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
