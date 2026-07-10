external hash_with_seed : string -> int -> int64 = "caml_xxh3_64_with_seed"

let hash_hex data seed = Printf.sprintf "%016Lx" (hash_with_seed data seed)

type state

external create : int -> state = "caml_xxh3_state_create"
external update : state -> string -> unit = "caml_xxh3_state_update"
external digest : state -> int64 = "caml_xxh3_state_digest"

let digest_hex s = Printf.sprintf "%016Lx" (digest s)
