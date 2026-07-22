module type S = sig
  val implementation : string
  val pre_start : mount_point:string -> unit

  val is_local :
    cache_root:string ->
    domain_name:string ->
    domain_prefix:string ->
    string ->
    bool

  val start : confs:(module Conf.S) list -> mount_fn:(string -> string) -> unit
end

let registry : (string, (module S)) Hashtbl.t = Hashtbl.create 4
let register name (m : (module S)) = Hashtbl.replace registry name m
let registered () = List.of_seq (Hashtbl.to_seq_values registry)
