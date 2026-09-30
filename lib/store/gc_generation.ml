open Tsync_core

let read (store : Store.t) d =
  match store.get_opt (Key.gc_generation d) with
    | None -> Some 0
    | Some b -> (
        match Yojson.Safe.from_string (Bigstring.to_string b) with
          | `Assoc f -> (
              match List.assoc_opt "generation" f with
                | Some (`Int g) when g >= 0 -> Some g
                | _ -> None)
          | _ -> None
          | exception _ -> None)

let encode g =
  Bigstring.of_string (Yojson.Safe.to_string (`Assoc [("generation", `Int g)]))
