let unknown ~known members =
  List.filter (fun (k, _) -> not (List.mem k known)) members
