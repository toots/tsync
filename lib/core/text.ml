let find_from s sub from =
  let n = String.length s and m = String.length sub in
  let rec at i =
    if i + m > n then None
    else if String.sub s i m = sub then Some i
    else at (i + 1)
  in
  at from

let contains s sub = find_from s sub 0 <> None

let replace_all ~sub ~by s =
  let b = Buffer.create (String.length s) in
  let rec go i =
    match find_from s sub i with
      | Some j ->
          Buffer.add_substring b s i (j - i);
          Buffer.add_string b by;
          go (j + String.length sub)
      | None -> Buffer.add_substring b s i (String.length s - i)
  in
  go 0;
  Buffer.contents b

let percent_escape ~allowed s =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      if allowed c then Buffer.add_char b c
      else Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents b

let percent_unescape s =
  let b = Buffer.create (String.length s) in
  let hex c =
    match c with
      | '0' .. '9' -> Some (Char.code c - 48)
      | 'a' .. 'f' -> Some (Char.code c - 87)
      | 'A' .. 'F' -> Some (Char.code c - 55)
      | _ -> None
  in
  let n = String.length s in
  let rec go i =
    if i >= n then Some (Buffer.contents b)
    else if s.[i] = '%' then
      if i + 2 >= n then None
      else (
        match (hex s.[i + 1], hex s.[i + 2]) with
          | Some a, Some c ->
              Buffer.add_char b (Char.chr ((a * 16) + c));
              go (i + 3)
          | _ -> None)
    else (
      Buffer.add_char b s.[i];
      go (i + 1))
  in
  go 0
