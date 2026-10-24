type t = {
  name : string;
  enrolled : int;
  last_unlock : int;
  seen : string list;
  modified : int;
}

let to_string t =
  Yojson.Safe.to_string
    (`Assoc
       [
         ("name", `String t.name);
         ("enrolled", `Int t.enrolled);
         ("lastUnlock", `Int t.last_unlock);
         ("seen", `List (List.map (fun id -> `String id) t.seen));
         ("modified", `Int t.modified);
       ])

let of_string body =
  match Yojson.Safe.from_string body with
    | `Assoc l -> (
        let int k =
          match List.assoc_opt k l with Some (`Int i) -> Some i | _ -> None
        in
        match
          ( List.assoc_opt "name" l,
            int "enrolled",
            int "lastUnlock",
            int "modified" )
        with
          | Some (`String name), Some enrolled, Some last_unlock, Some modified
            when name <> "" && String.length name <= 256 ->
              Ok
                {
                  name;
                  enrolled;
                  last_unlock;
                  seen =
                    (match List.assoc_opt "seen" l with
                      | Some (`List ids) ->
                          List.filter_map
                            (function `String id -> Some id | _ -> None)
                            ids
                      | _ -> []);
                  modified;
                }
          | _ -> Error "not a machine entry")
    | _ -> Error "not a machine entry"
    | exception Yojson.Json_error _ -> Error "not JSON"
