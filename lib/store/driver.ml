open Tsync_core

type t = {
  fields : Field_spec.field list;
  linkless : bool;
  create :
    domain:Domain_name.t ->
    admission:Uplink.t ->
    name:string ->
    (string * Field_spec.value) list ->
    Store.t;
}

let registry = Registry.create ()
let register = Registry.register registry
let find = Registry.find registry
let names () = Registry.names registry
