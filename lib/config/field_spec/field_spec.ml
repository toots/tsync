type typ = [ `String | `Bool | `Int ]

type t = {
  name : string;
  label : string;
  typ : typ;
  default : string option;
  secret : bool;
}

(* Everything reaches a driver as a string: [tsync configure] writes a JSON
   boolean and {!Conf_parsing} flattens it with [string_of_bool], but a
   hand-edited config holds whatever someone typed.

   Here rather than at each reader because the spellings had drifted — a field
   taking ["1"] for true while another took only ["true"], and a field defaulting
   on deciding the question the opposite way round from one defaulting off. What
   a setting is called and what counts as setting it belong together. *)
let bool ~default v =
  match Option.map String.lowercase_ascii v with
    | Some ("true" | "1" | "yes" | "on") -> true
    | Some ("false" | "0" | "no" | "off") -> false
    (* Neither, or nothing: the declared default, never an accident of which
       comparison the reader happened to write. *)
    | Some _ | None -> default
