type t = Path_glob.Glob.globber

let of_pattern p = Path_glob.Glob.parse ("<" ^ p ^ ">")
let matches g s = Path_glob.Glob.eval g s
