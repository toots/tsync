let send ~socket_path cmd =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.connect fd (Unix.ADDR_UNIX socket_path);
  let ic = Unix.in_channel_of_descr fd in
  let oc = Unix.out_channel_of_descr fd in
  output_string oc (cmd ^ "\n");
  flush oc;
  let resp = input_line ic in
  Unix.close fd;
  resp

let request ~socket_path fields =
  let body = Yojson.Safe.to_string (`Assoc fields) in
  match Yojson.Safe.from_string (send ~socket_path body) with
    | `Assoc obj when List.assoc_opt "ok" obj = Some (`Bool true) -> obj
    | `Assoc obj ->
        let msg =
          match List.assoc_opt "error" obj with
            | Some (`String s) -> s
            | _ -> "unexpected response"
        in
        failwith msg
    | _ -> failwith "unexpected response"

let action ~socket_path ?item ?arg ?domain action =
  request ~socket_path
    ([("action", `String action)]
    @ (match item with
      | Some r -> [("ref", `String (Item_ref.to_string r))]
      | None -> [])
    @ (match domain with Some d -> [("domain", `String d)] | None -> [])
    @ match arg with Some a -> [("arg", `String a)] | None -> [])
