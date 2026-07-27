(* Cache chunks: a run of consecutive stored chunks, cached as a single file.

   The two granularities pull in opposite directions. A stored chunk is network
   granularity — smaller means less egress when a file changes and finer dedup.
   A cache chunk is disk granularity — larger means fewer opens and less I/O
   latency per read. This module is the seam between them, and the only place
   that knows a cache file holds more than one stored chunk. *)

type t = {
  key : string;
  members : string array;  (** stored chunk keys, in index order *)
  sizes : int array;
  first : int;  (** stored index of [members.(0)] *)
}

(* Stored chunks per cache chunk: the n that puts n * chunk_size closest to
   cache_chunk_size. Integer round-half-up, so a tie takes the larger group. *)
let per_group ~chunk_size ~cache_chunk_size =
  if chunk_size <= 0 then 1
  else max 1 ((cache_chunk_size + (chunk_size / 2)) / chunk_size)

(* The group's name, hashed over its member keys — not "<first>-<last>". Two
   groups can share their first and last chunk and differ in between (a run of
   identical chunks, which any all-zero region gives you), and aliasing two
   groups onto one cache file serves one file's bytes for the other's. Same
   shape as a chunk key, so the fanout directory is unchanged. *)
let key_of members =
  let s1 = Xxhash.create 0 and s2 = Xxhash.create 1 in
  Array.iter
    (fun k ->
      Xxhash.update s1 k;
      Xxhash.update s2 k;
      Xxhash.update s1 ";";
      Xxhash.update s2 ";")
    members;
  Xxhash.digest_hex s1 ^ "-" ^ Xxhash.digest_hex s2

(* The group holding stored chunk [i]. [None] when the manifest has a hole in
   it: a group is only addressable if every member it names is there. *)
let of_specs ~specs ~per i =
  let n = Array.length specs in
  if per <= 0 || i < 0 || i >= n then None
  else (
    let first = i / per * per in
    let len = min per (n - first) in
    let members = Array.make len "" and sizes = Array.make len 0 in
    let rec fill j =
      if j >= len then Some { key = key_of members; members; sizes; first }
      else (
        match specs.(first + j) with
          | None -> None
          | Some (key, size) ->
              members.(j) <- key;
              sizes.(j) <- size;
              fill (j + 1))
    in
    fill 0)

(* Every group of a file, skipping any the manifest cannot describe. *)
let all ~specs ~per =
  let n = Array.length specs in
  if per <= 0 then []
  else (
    let rec go i acc =
      if i >= n then List.rev acc
      else
        go (i + per)
          (match of_specs ~specs ~per i with Some g -> g :: acc | None -> acc)
    in
    go 0 [])

let count ~specs ~per =
  if per <= 0 then 0 else (Array.length specs + per - 1) / per

let index_of ~per i = i / per
let member_count t = Array.length t.sizes
let indices t = List.init (Array.length t.sizes) (fun j -> t.first + j)
let size t i = t.sizes.(i - t.first)
let member_key t i = t.members.(i - t.first)

(* Byte offset of stored chunk [i] within the group body. A prefix sum rather
   than [(i - first) * chunk_size]: the file's last chunk is short. *)
let offset t i =
  let last = min (member_count t) (max 0 (i - t.first)) in
  let rec go j acc =
    if j >= last then acc else go (j + 1) (acc + t.sizes.(j))
  in
  go 0 0

let bytes t = Array.fold_left ( + ) 0 t.sizes
let members t = Array.to_list t.members
let key t = t.key
