let body ?computed ?reason size =
  Yojson.Safe.to_string
    (`Assoc
       (List.filter_map Fun.id
          [
            Option.map (fun c -> ("computed", `String c)) computed;
            Option.map (fun s -> ("size", `Int s)) size;
            Some ("at", `Float (Unix.gettimeofday ()));
            Option.map (fun r -> ("reason", `String r)) reason;
          ]))
