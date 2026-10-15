let json =
  match Yojson.Safe.from_string Mime_json.json with `Assoc l -> l | _ -> []

let table =
  List.filter_map (function k, `String v -> Some (k, v) | _ -> None) json

let signatures =
  let bytes = function
    | o, `Int b -> Option.map (fun o -> (o, b)) (int_of_string_opt o)
    | _ -> None
  in
  match List.assoc_opt "@signatures" json with
    | Some (`Assoc l) ->
        List.filter_map
          (function
            | ext, `Assoc f -> (
                match (List.assoc_opt "type" f, List.assoc_opt "bytes" f) with
                  | Some (`String ty), Some (`Assoc b) ->
                      Some (ext, (ty, List.filter_map bytes b))
                  | _ -> None)
            | _ -> None)
          l
    | _ -> []

let extension name =
  match String.rindex_opt name '.' with
    | Some i ->
        String.lowercase_ascii
          (String.sub name (i + 1) (String.length name - i - 1))
    | None -> ""

let of_name name = List.assoc_opt (extension name) table

let served ~size ~head name =
  match List.assoc_opt (extension name) signatures with
    | Some (ty, bytes) when size > 0 ->
        let at = List.filter (fun (o, _) -> o < size) bytes in
        let h = head (List.fold_left (fun n (o, _) -> max n (o + 1)) 0 at) in
        if
          List.for_all
            (fun (o, b) -> o < String.length h && Char.code h.[o] = b)
            at
        then Some ty
        else of_name name
    | _ -> of_name name
