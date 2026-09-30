open Tsync_core

type t = {
  fields : Field_spec.field list;
  presenting : [ `Per_domain | `Shared ] option;
  commands_only : string option;
}

let registry = Registry.create ()
let register = Registry.register registry
let find = Registry.find registry
let names () = Registry.names registry
