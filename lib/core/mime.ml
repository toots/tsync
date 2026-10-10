let table =
  match Yojson.Safe.from_string Mime_json.json with
    | `Assoc l ->
        List.filter_map (function k, `String v -> Some (k, v) | _ -> None) l
    | _ -> []

let extension name =
  match String.rindex_opt name '.' with
    | Some i ->
        String.lowercase_ascii
          (String.sub name (i + 1) (String.length name - i - 1))
    | None -> ""

let of_name name = List.assoc_opt (extension name) table
