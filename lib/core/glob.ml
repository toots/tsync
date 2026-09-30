let matches pattern path =
  let pl = String.length pattern and sl = String.length path in
  let seg_start i = i = 0 || pattern.[i - 1] = '/' in
  let rec m i j =
    if i = pl then j = sl
    else if
      seg_start i
      && i + 1 < pl
      && pattern.[i] = '*'
      && pattern.[i + 1] = '*'
      && (i + 2 = pl || pattern.[i + 2] = '/')
    then
      if i + 2 = pl then true
      else (
        let rest = i + 3 in
        let rec after k =
          k <= sl
          && (m rest k
             ||
               match String.index_from_opt path k '/' with
               | Some n -> after (n + 1)
               | None -> false)
        in
        after j)
    else (
      match pattern.[i] with
        | '*' ->
            let rec skip i =
              if i < pl && pattern.[i] = '*' then skip (i + 1) else i
            in
            let i' = skip i in
            let rec try_ k =
              m i' k || (k < sl && path.[k] <> '/' && try_ (k + 1))
            in
            try_ j
        | '?' -> j < sl && path.[j] <> '/' && m (i + 1) (j + 1)
        | c -> j < sl && path.[j] = c && m (i + 1) (j + 1))
  in
  m 0 0
