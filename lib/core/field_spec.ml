type typ = [ `String | `Bool | `Int ]

type t = {
  name : string;
  label : string;
  typ : typ;
  default : string option;
  secret : bool;
}

let bool ~default v =
  match Option.map String.lowercase_ascii v with
    | Some ("true" | "1" | "yes" | "on") -> true
    | Some ("false" | "0" | "no" | "off") -> false
    | Some _ | None -> default
