open Tsync_core

type command = {
  verb : string;
  doc : string;
  run : domain:string -> string list -> int;
}

type wizard = {
  systems : [ `Linux | `Macos ] list;
  question : string;
  asks : string list;
}

type t = {
  fields : Field_spec.field list;
  wizard : wizard option;
  presenting : [ `Per_domain | `Shared ] option;
  commands_only : string option;
  pulled : string option;
  group : string option;
  commands : command list;
}

let registry = Registry.create ()
let register = Registry.register registry
let find = Registry.find registry
let names () = Registry.names registry

let offered system =
  List.filter_map
    (fun name ->
      match find name with
        | Some ({ wizard = Some w; _ } as f) when List.mem system w.systems ->
            Some (name, f)
        | _ -> None)
    (names ())
  |> List.stable_sort (fun (_, a) (_, b) ->
      compare (b.presenting <> None) (a.presenting <> None))
