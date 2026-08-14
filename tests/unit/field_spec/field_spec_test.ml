(* Every driver and frontend reads its [`Bool] settings through one function.
   The spelling used to live at each reader and they had drifted: ["1"] meant
   true for one field and false for another, and a field defaulting on answered
   the question the opposite way round from one defaulting off — so ["no"]
   turned a setting on.

   A table rather than assertions, because what matters is that both columns
   agree everywhere except where the value says nothing: the two defaults are
   what the readers used to disagree about. *)

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
      (* What [tsync configure] writes and [Conf_parsing] flattens. *)
      Some "true";
      Some "false";
      (* Hand-edited configs. Each of these was read two ways before. *)
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
