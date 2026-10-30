type reason = [ `Unpresentable of string | `Case_group of string ]

let decode leaf =
  let b = Buffer.create (String.length leaf) in
  let rec go i units =
    if i >= String.length leaf then units
    else (
      let d = String.get_utf_8_uchar leaf i in
      let u = Uchar.utf_decode_uchar d in
      Buffer.add_utf_8_uchar b u;
      go
        (i + Uchar.utf_decode_length d)
        (units + if Uchar.to_int u > 0xFFFF then 2 else 1))
  in
  let units = go 0 0 in
  (Buffer.contents b, units)

let reserved_stems =
  ["CON"; "PRN"; "AUX"; "NUL"]
  @ List.concat_map
      (fun dev ->
        List.init 10 (fun n -> dev ^ string_of_int n)
        @ List.map (fun sup -> dev ^ sup) ["\xc2\xb9"; "\xc2\xb2"; "\xc2\xb3"])
      ["COM"; "LPT"]

let refused_char = function
  | '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*' -> true
  | c -> Char.code c < 0x20

let presentable leaf =
  let name, units = decode leaf in
  let stem =
    match String.index_opt name '.' with
      | Some i -> String.sub name 0 i
      | None -> name
  in
  let last = if name = "" then None else Some name.[String.length name - 1] in
  if name = "" then Error "an empty name"
  else if units > 255 then Error "longer than 255 UTF-16 code units"
  else if String.exists refused_char name then
    Error "a character Windows refuses in a name"
  else if last = Some ' ' || last = Some '.' then
    Error "a name ending with a space or a dot"
  else if List.mem (String.uppercase_ascii stem) reserved_stems then
    Error "a reserved device name"
  else Ok name

let choose ~fold ~on_disk children =
  let shown, refused =
    List.partition_map
      (fun (leaf, x) ->
        match presentable leaf with
          | Ok name -> Left (x, leaf, name)
          | Error why -> Right (x, `Unpresentable why))
      children
  in
  let groups = Hashtbl.create 16 in
  List.iter
    (fun ((_, leaf, name) as c) ->
      let key = fold name in
      let winner =
        match Hashtbl.find_opt groups key with
          | None -> c
          | Some ((_, wleaf, wname) as w) ->
              let held n = on_disk n in
              if held wname && not (held name) then w
              else if held name && not (held wname) then c
              else if String.compare leaf wleaf < 0 then c
              else w
      in
      Hashtbl.replace groups key winner)
    shown;
  let presented, grouped =
    List.partition_map
      (fun ((x, _, name) as c) ->
        let ((_, _, wname) as w) = Hashtbl.find groups (fold name) in
        if w == c then Left (x, name) else Right (x, `Case_group wname))
      shown
  in
  (presented, (refused :> ('a * reason) list) @ grouped)
