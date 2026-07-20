(* A manifest's in-memory key is [domain_prefix ^ real-relative-path]. On the
   backend it is stored under a hashed key: the literal [manifests/] prefix is
   kept, and every real path component after it is replaced by its xxHash
   dual-seed hex. Keys are then fixed-length and valid on any filesystem, so the
   real name never has to survive as a path component (it lives in the manifest
   body instead).
   ponytail: 128-bit component key space; sibling-name collisions are ignorable. *)

let hash_component c =
  if c = "" then c else Xxhash.hash_hex c 0 ^ "-" ^ Xxhash.hash_hex c 1

let hash_rel rel =
  String.split_on_char '/' rel |> List.map hash_component |> String.concat "/"

let rel ~domain_prefix key =
  let pfx = String.length domain_prefix in
  if String.length key >= pfx && String.sub key 0 pfx = domain_prefix then
    String.sub key pfx (String.length key - pfx)
  else key

(* Map an in-memory manifest key to its hashed backend key. *)
let of_key ~domain_prefix key =
  let pfx = String.length domain_prefix in
  if String.length key >= pfx && String.sub key 0 pfx = domain_prefix then
    domain_prefix ^ hash_rel (rel ~domain_prefix key)
  else key
