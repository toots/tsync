let norm p =
  let p = Cf.upcase (String.map (function '/' -> '\\' | c -> c) p) in
  if String.ends_with ~suffix:"\\" p then String.sub p 0 (String.length p - 1)
  else p

let same a b = norm a = norm b
