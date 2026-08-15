(* Every driver and frontend reads its [`Bool] settings through one function.

   A table rather than assertions, because what matters is that both defaults
   agree everywhere except where the value itself says nothing. *)

let show = function true -> "true " | false -> "false"

let () =
  print_endline "value            default:false  default:true";
  List.iter
    (fun v ->
      Printf.printf "%-16s %s          %s\n"
        (match v with None -> "(absent)" | Some s -> Printf.sprintf "%S" s)
        (show (Field_spec.bool ~default:false v))
        (show (Field_spec.bool ~default:true v)))
    [
      (* What [tsync config --edit] writes and [Conf_parsing] flattens. *)
      Some "true";
      Some "false";
      (* Hand-edited configs. *)
      Some "1";
      Some "0";
      Some "yes";
      Some "no";
      Some "on";
      Some "off";
      Some "TRUE";
      Some "Off";
      (* Nothing recognisable, and nothing at all: the declared default, never
         an accident of which comparison a reader happened to write. *)
      Some "perhaps";
      Some "";
      None;
    ]
