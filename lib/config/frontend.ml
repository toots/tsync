open Tsync_core

type command = {
  verb : string;
  doc : string;
  run : domain:string -> string list -> int;
}

type t = {
  fields : Field_spec.field list;
  presenting : [ `Per_domain | `Shared ] option;
  commands_only : string option;
  group : string option;
  commands : command list;
}

let registry = Registry.create ()
let register = Registry.register registry
let find = Registry.find registry
let names () = Registry.names registry
