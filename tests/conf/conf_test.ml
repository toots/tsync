(* Checks primary-backend selection: explicit [main] wins, else first local,
   else first configured. order_backends moves the primary to the head. *)
let bc ?(main = false) backend_type id =
  Conf_parsing.{ backend_type; name = id; fields = [("id", id)]; main }

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
  (* array fields (exec backend "command") pass through as JSON strings *)
  Unix.putenv "TSYNC_CONFIG_JSON"
    {|{"domains": [{"name": "d", "symlinks": "keep", "versioning": false,
                    "frontends": ["fuse"],
                    "backends": [{"type": "exec", "name": "e", "path": "/x",
                                  "command": ["ssh", "box"]}]}]}|};
  let cfg = Conf_parsing.load "" in
  let backend =
    List.hd (List.hd cfg.Conf_parsing.domains).Conf_parsing.backends
  in
  assert (List.assoc "command" backend.Conf_parsing.fields = {|["ssh","box"]|});

  (* frontends: bare string and object forms both parse; string = {type};
     object keys beyond "type" are kept as option fields *)
  Unix.putenv "TSYNC_CONFIG_JSON"
    {|{"domains": [{"name": "d", "symlinks": "keep", "versioning": false,
                    "frontends": ["fuse", {"type": "http", "port": "8080"}],
                    "backends": [{"type": "s3", "name": "s"}]}]}|};
  (match
     (List.hd (Conf_parsing.load "").Conf_parsing.domains)
       .Conf_parsing.frontends
   with
    | [a; b] ->
        assert (
          a.Conf_parsing.frontend_type = "fuse" && a.Conf_parsing.options = []);
        assert (b.Conf_parsing.frontend_type = "http");
        assert (List.assoc "port" b.Conf_parsing.options = "8080")
    | _ -> assert false);

  Unix.putenv "TSYNC_CONFIG_JSON" "";
  print_endline "conf_test ok"
