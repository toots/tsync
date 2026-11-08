type t = { anchor : string; pending : string list }

let fresh = { anchor = ""; pending = ["root"] }

let encode t =
  Yojson.Safe.to_string
    (`Assoc
       [
         ("anchor", `String t.anchor);
         ("pending", `List (List.map (fun r -> `String r) t.pending));
       ])

let decode text =
  match Yojson.Safe.from_string text with
    | `Assoc fields -> (
        match
          (List.assoc_opt "anchor" fields, List.assoc_opt "pending" fields)
        with
          | Some (`String anchor), Some (`List refs) ->
              let pending =
                List.filter_map
                  (function `String r -> Some r | _ -> None)
                  refs
              in
              if List.length pending = List.length refs then
                Some { anchor; pending }
              else None
          | _ -> None)
    | _ -> None
    | exception Yojson.Json_error _ -> None
