(* Cache chunks: a run of consecutive stored chunks, cached as a single file.

   The two granularities pull opposite ways. A stored chunk is network
   granularity: smaller means less egress when a file changes and finer dedup. A
   cache chunk is disk granularity: larger means fewer opens and less latency per
   read. This is the seam, and the only place knowing a cache file holds more
   than one stored chunk. *)

type t = {
  key : string;
  members : string array;  (** stored chunk keys, in index order *)
  sizes : int array;
  first : int;  (** stored index of [members.(0)] *)
}

(* The n putting n * chunk_size closest to cache_chunk_size. Round-half-up, so a
   tie takes the larger group. *)
let per_group ~chunk_size ~cache_chunk_size =
  if chunk_size <= 0 then 1
  else max 1 ((cache_chunk_size + (chunk_size / 2)) / chunk_size)

(* Hashed over the member keys, not "<first>-<last>": two groups can share their
   first and last chunk and differ in between (any run of identical chunks does
   it), and aliasing them onto one cache file serves the wrong bytes. Same shape
   as a chunk key, so the fanout directory is unchanged. *)
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

(* [None] only when [i] is out of range: {!Chunk_table} rejects at decode any
   body whose length disagrees with its header, so every index below [count] has
   a key. *)
let of_table ~table ~per i =
  let n = Chunk_table.count table in
  if per <= 0 || i < 0 || i >= n then None
  else (
    let first = i / per * per in
    let len = min per (n - first) in
    let members = Array.init len (fun j -> Chunk_table.key table (first + j)) in
    Some
      {
        key = key_of members;
        members;
        sizes = Array.init len (fun j -> Chunk_table.len table (first + j));
        first;
      })

let all ~table ~per =
  let n = Chunk_table.count table in
  if per <= 0 then []
  else (
    let rec go i acc =
      if i >= n then List.rev acc
      else
        go (i + per)
          (match of_table ~table ~per i with Some g -> g :: acc | None -> acc)
    in
    go 0 [])

let count ~table ~per =
  if per <= 0 then 0 else (Chunk_table.count table + per - 1) / per

let index_of ~per i = i / per
let member_count t = Array.length t.sizes
let indices t = List.init (Array.length t.sizes) (fun j -> t.first + j)
let size t i = t.sizes.(i - t.first)
let member_key t i = t.members.(i - t.first)

(* A prefix sum rather than [(i - first) * chunk_size]: the file's last chunk is
   short. *)
let offset t i =
  let last = min (member_count t) (max 0 (i - t.first)) in
  let rec go j acc =
    if j >= last then acc else go (j + 1) (acc + t.sizes.(j))
  in
  go 0 0

let bytes t = Array.fold_left ( + ) 0 t.sizes
let key t = t.key
