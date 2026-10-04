let take n l =
  let rec go n acc = function
    | x :: rest when n > 0 -> go (n - 1) (x :: acc) rest
    | rest -> (List.rev acc, rest)
  in
  go n [] l

let rec cut n = function
  | [] -> []
  | l ->
      let page, rest = take n l in
      page :: cut n rest
