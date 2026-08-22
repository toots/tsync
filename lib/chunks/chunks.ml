let key_of_body data =
  Xxhash.hash_bigstring_hex data 0 ^ "-" ^ Xxhash.hash_bigstring_hex data 1

let is_chunk_key name =
  match String.index_opt name '-' with
    | Some i when i = Xxhash.hex_length ->
        Xxhash.is_hex (String.sub name 0 i)
        && Xxhash.is_hex (String.sub name (i + 1) (String.length name - i - 1))
    | _ -> false

let count ~size ~chunk_size =
  let s = Int64.to_int size in
  if s <= 0 then 0 else (s + chunk_size - 1) / chunk_size

let index_of ~chunk_size pos = pos / chunk_size
let offset_of ~chunk_size i = i * chunk_size

(* A chunk_size of zero reads as a chunk holding nothing rather than dividing by
   it: a symlink body carries no chunks and no size to cut. *)
let length_of ~size ~chunk_size i =
  max 0 (min chunk_size (Int64.to_int size - (i * chunk_size)))
