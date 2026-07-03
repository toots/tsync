(* Checks primary-backend selection: explicit [main] wins, else first local,
   else first configured. order_backends moves the primary to the head. *)
let bc ?(main = false) backend_type id =
  Conf_parsing.{ backend_type; fields = [("id", id)]; main }

let ids bs =
  List.map
    (fun b -> List.assoc "id" b.Conf_parsing.fields)
    (Conf_parsing.order_backends bs)

let () =
  (* explicit main wins over local-first and list order *)
  assert (
    ids [bc "s3" "a"; bc "local" "b"; bc ~main:true "s3" "c"] = ["c"; "a"; "b"]);
  (* no main -> first local backend *)
  assert (ids [bc "s3" "a"; bc "local" "b"; bc "local" "c"] = ["b"; "a"; "c"]);
  (* no main, no local -> first configured *)
  assert (ids [bc "s3" "a"; bc "s3" "b"] = ["a"; "b"]);
  (* single backend is unchanged *)
  assert (ids [bc "s3" "a"] = ["a"]);
  print_endline "conf_test ok"
