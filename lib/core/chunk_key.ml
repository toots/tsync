type t = string

let of_string s = if Names.is_chunk_key s then Some s else None

let v s =
  match of_string s with
    | Some k -> k
    | None -> Fail.corrupt "invalid chunk key %S" s

let of_body = Xxh.dual
let of_bigstring ?off ?len b = Xxh.dual_bigstring ?off ?len b
let to_string k = k
let shard k = String.sub k 0 3
let empty = Xxh.dual ""
let equal = String.equal
let compare = String.compare
let names k b = equal (of_bigstring b) k
