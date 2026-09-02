(* Written by whatever took the write: this client for a local store, the
   bucket's function for s3 and gcs — which is why the codec tolerates fields it
   does not know and fields that are not there. *)

type t = {
  computed : string option;
  size : int option;
  at : float option;
  reason : string option;
}

let empty = { computed = None; size = None; at = None; reason = None }

let to_string { computed; size; at; reason } =
  Yojson.Safe.to_string
    (`Assoc
       (List.filter_map Fun.id
          [
            Option.map (fun c -> ("computed", `String c)) computed;
            Option.map (fun s -> ("size", `Int s)) size;
            Option.map (fun a -> ("at", `Float a)) at;
            Option.map (fun r -> ("reason", `String r)) reason;
          ]))

let of_string body =
  match Yojson.Safe.from_string body with
    | exception _ -> empty
    | json ->
        let member name =
          match json with
            | `Assoc fields -> List.assoc_opt name fields
            | _ -> None
        in
        {
          computed =
            (match member "computed" with
              | Some (`String s) -> Some s
              | _ -> None);
          size =
            (match member "size" with Some (`Int n) -> Some n | _ -> None);
          at =
            (match member "at" with
              | Some (`Float f) -> Some f
              | Some (`Int n) -> Some (float_of_int n)
              | _ -> None);
          reason =
            (match member "reason" with
              | Some (`String r) -> Some r
              | _ -> None);
        }
