let name ~client ~is_dir leaf n =
  let tag =
    if n <= 1 then Printf.sprintf " (conflicted copy from %s)" client
    else Printf.sprintf " (conflicted copy %d from %s)" n client
  in
  if is_dir then leaf ^ tag
  else (
    match String.rindex_opt leaf '.' with
      | Some i when i > 0 ->
          String.sub leaf 0 i ^ tag ^ String.sub leaf i (String.length leaf - i)
      | _ -> leaf ^ tag)
