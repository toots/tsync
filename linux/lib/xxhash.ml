external hash_with_seed : string -> int -> int64 = "caml_xxh3_64_with_seed"
let hash_hex data seed = Printf.sprintf "%016Lx" (hash_with_seed data seed)
