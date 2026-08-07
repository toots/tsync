type typ = [ `String | `Bool | `Int ]

type t = {
  name : string;
  label : string;
  typ : typ;
  default : string option;
  secret : bool;
}
