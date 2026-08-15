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

(* Derived rather than spelled, so the store's own root lives in exactly one
   place ({!Conf_parsing.root_prefix}) and this cannot drift from it.

   A domain named "corrupted" or "verify-jobs" would collide with these. Nothing
   forbids it; it has simply never been worth a check against two words. *)
let store_root ~chunk_prefix =
  match String.index_opt chunk_prefix '/' with
    | Some i -> String.sub chunk_prefix 0 (i + 1)
    | None -> ""

let corrupted_root ~chunk_prefix = store_root ~chunk_prefix ^ "corrupted/"
let verify_jobs_root ~chunk_prefix = store_root ~chunk_prefix ^ "verify-jobs/"

(* The domain a chunk prefix belongs to: ["tsync/<domain>/chunks/"] is the one
   shape this ever sees. *)
let domain_of ~chunk_prefix =
  let root = Filename.chop_suffix chunk_prefix "chunks/" in
  let root =
    if root <> "" && root.[String.length root - 1] = '/' then
      String.sub root 0 (String.length root - 1)
    else root
  in
  match String.index_opt root '/' with
    | Some i -> String.sub root (i + 1) (String.length root - i - 1)
    | None -> root

let corrupted_prefix ~chunk_prefix =
  corrupted_root ~chunk_prefix ^ domain_of ~chunk_prefix ^ "/"

let verify_jobs_prefix ~chunk_prefix =
  verify_jobs_root ~chunk_prefix ^ domain_of ~chunk_prefix ^ "/"

let verify_job_key ~chunk_prefix shard =
  verify_jobs_prefix ~chunk_prefix ^ shard

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

(* ["tsync/<domain>/chunks/<shard>/<key>"] becomes
   ["corrupted/<domain>/<shard>/<key>"].

   [None] for a marker key, for anything under [chunks.from/], and for a manifest
   — which is filed under the hash of its own file name and so is spelled exactly
   like a chunk key. Membership is the prefix, never the shape of the name. *)
let marker_key key =
  match rfind_seg key chunks_seg with
    | None -> None
    | Some i -> (
        let root = String.sub key 0 i in
        let start = i + String.length chunks_seg in
        let rest = String.sub key start (String.length key - start) in
        match (String.index_opt rest '/', String.index_opt root '/') with
          (* [k + 1 < length root] rejects an empty domain: a marker filed under
             one would sit at a prefix nothing lists, since every reader builds
             that prefix from a domain name. The Python does the same. *)
          | Some j, Some k
            when k + 1 < String.length root
                 && is_shard_name (String.sub rest 0 j)
                 && is_chunk_key
                      (String.sub rest (j + 1) (String.length rest - j - 1)) ->
              Some
                (String.sub root 0 (k + 1)
                ^ "corrupted/"
                ^ String.sub root (k + 1) (String.length root - k - 1)
                ^ "/" ^ rest)
          | _ -> None)

(* True for exactly what {!marker_key} produces. A directory is not a marker — a
   filesystem store makes one to hold markers and lists it back — so the whole
   shape is asked for, not the prefix. *)
let is_marker_key key =
  match String.index_opt key '/' with
    | None -> false
    | Some r ->
        let after = String.sub key (r + 1) (String.length key - r - 1) in
        if not (String.starts_with ~prefix:"corrupted/" after) then false
        else (
          let rest =
            String.sub after
              (String.length "corrupted/")
              (String.length after - String.length "corrupted/")
          in
          match String.rindex_opt rest '/' with
            | None -> false
            | Some j -> (
                let leaf =
                  String.sub rest (j + 1) (String.length rest - j - 1)
                in
                let head = String.sub rest 0 j in
                match String.rindex_opt head '/' with
                  | Some k ->
                      is_shard_name
                        (String.sub head (k + 1) (String.length head - k - 1))
                      && is_chunk_key leaf
                  | None -> false))

let chunk_key_of_marker = Filename.basename
