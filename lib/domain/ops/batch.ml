let take n l =
  let rec go acc n = function
    | rest when n <= 0 -> (List.rev acc, rest)
    | [] -> (List.rev acc, [])
    | x :: rest -> go (x :: acc) (n - 1) rest
  in
  go [] n l

let per_delete = 1000
