(* Where a chunk key lives, relative to a chunk store's root, shared by the
   backend store and the local cache.

   Three characters splits a store 4096 ways: a few hundred files per shard for a
   10 TB store at the default chunk size, small enough that readdir stays cheap
   without tens of thousands of near-empty directories. *)
let fanout = 3
let shards = 1 lsl (4 * fanout)
let shard_name n = Printf.sprintf "%0*x" fanout n

let relative_path key =
  let shard =
    if String.length key >= fanout then String.sub key 0 fanout else "_"
  in
  Filename.concat shard key

(* Both are asked while walking a directory, where the answer decides whether
   something gets copied or deleted, so both state what the name is rather than
   what it is not -- see {!Xxhash.is_hex}. *)
let is_chunk_key name =
  match String.index_opt name '-' with
    | Some i when i = Xxhash.hex_length ->
        Xxhash.is_hex (String.sub name 0 i)
        && Xxhash.is_hex (String.sub name (i + 1) (String.length name - i - 1))
    | _ -> false

let is_shard_name name =
  String.length name = fanout
  && String.for_all
       (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
       name

(* Here rather than beside the manifest that publishes it, so a store can hold a
   body against its own name without depending on the shapes that reference it. *)
let key_of_body data = Xxhash.hash_hex data 0 ^ "-" ^ Xxhash.hash_hex data 1
let chunks_seg = "/chunks/"
let corrupted_seg = "/corrupted/"

let sibling ~chunk_prefix name =
  Filename.chop_suffix chunk_prefix "chunks/" ^ name

let corrupted_prefix ~chunk_prefix = sibling ~chunk_prefix "corrupted/"
let verify_jobs_prefix ~chunk_prefix = sibling ~chunk_prefix "verify-jobs/"

let verify_job_key ~chunk_prefix shard =
  verify_jobs_prefix ~chunk_prefix ^ shard

(* Beside the namespaces rather than inside one, and derived from whatever prefix
   a caller happens to hold: [capabilities] is asked with the manifest prefix,
   [verify_all] with the chunk prefix, and both mean the same domain. *)
let verifier_key ~prefix =
  let trimmed =
    if String.length prefix > 0 && prefix.[String.length prefix - 1] = '/' then
      String.sub prefix 0 (String.length prefix - 1)
    else prefix
  in
  match String.rindex_opt trimmed '/' with
    | Some i -> String.sub trimmed 0 (i + 1) ^ "verifier"
    | None -> "verifier"

(* The shard a job names, or [None] for anything else under the prefix. *)
let shard_of_verify_job key =
  let leaf = Filename.basename key in
  if is_shard_name leaf then Some leaf else None

(* Last, not first: a domain named "chunks" would otherwise cut the key short. *)
let rfind_seg s seg =
  let n = String.length s and m = String.length seg in
  let rec go i =
    if i < 0 then None else if String.sub s i m = seg then Some i else go (i - 1)
  in
  if m > n then None else go (n - m)

let marker_key key =
  match rfind_seg key chunks_seg with
    | None -> None
    | Some i -> (
        let root = String.sub key 0 i in
        let start = i + String.length chunks_seg in
        let rest = String.sub key start (String.length key - start) in
        match String.index_opt rest '/' with
          | Some j
            when is_shard_name (String.sub rest 0 j)
                 && is_chunk_key
                      (String.sub rest (j + 1) (String.length rest - j - 1)) ->
              Some (root ^ corrupted_seg ^ rest)
          | _ -> None)

let is_marker_key key =
  match rfind_seg key corrupted_seg with
    | None -> false
    | Some i -> (
        let start = i + String.length corrupted_seg in
        let rest = String.sub key start (String.length key - start) in
        match String.index_opt rest '/' with
          | Some j ->
              is_shard_name (String.sub rest 0 j)
              && is_chunk_key
                   (String.sub rest (j + 1) (String.length rest - j - 1))
          | None -> false)

let chunk_key_of_marker = Filename.basename
