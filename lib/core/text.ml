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
