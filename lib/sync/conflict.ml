let with_tag ~is_dir leaf tag =
  if is_dir then leaf ^ tag
  else (
    match String.rindex_opt leaf '.' with
      | Some i when i > 0 ->
          String.sub leaf 0 i ^ tag ^ String.sub leaf i (String.length leaf - i)
      | _ -> leaf ^ tag)

let name ~client ~is_dir leaf n =
  with_tag ~is_dir leaf
    (if n <= 1 then Printf.sprintf " (conflicted copy from %s)" client
     else Printf.sprintf " (conflicted copy %d from %s)" n client)

let clash_name ~is_dir leaf n =
  with_tag ~is_dir leaf
    (if n <= 1 then " (name clash)" else Printf.sprintf " (name clash %d)" n)

let rec first_free ~taken candidate n =
  let c = candidate n in
  if taken c then first_free ~taken candidate (n + 1) else c

let free ?(n = 1) ~client ~is_dir ~taken leaf =
  first_free ~taken (name ~client ~is_dir leaf) n

let free_clash ~is_dir ~taken leaf =
  first_free ~taken (clash_name ~is_dir leaf) 1
