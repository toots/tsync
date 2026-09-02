type typ = [ `String | `Bool | `Int ]

type t = {
  name : string;
  label : string;
  typ : typ;
  default : string option;
  secret : bool;
}

let masked = "***"
let mask (s : t) v = if s.secret && v <> "" then masked else v

let mask_named spec name v =
  match List.find_opt (fun (s : t) -> s.name = name) spec with
    | Some s -> mask s v
    | None -> v

let bool ~default v =
  match Option.map String.lowercase_ascii v with
    | Some ("true" | "1" | "yes" | "on") -> true
    | Some ("false" | "0" | "no" | "off") -> false
    | Some _ | None -> default
