(* Where a chunk key lives, relative to a chunk store's root, shared by the
   backend store and the local cache.

   Three characters splits a store 4096 ways: a few hundred files per shard for a
   10 TB store at the default chunk size, small enough that readdir stays cheap
   without tens of thousands of near-empty directories. *)
let fanout = 3
let shards = 1 lsl (4 * fanout)
let shard_name n = Printf.sprintf "%0*x" fanout n

let shard_of key =
  if String.length key >= fanout then String.sub key 0 fanout else "_"

let relative_path key = Filename.concat (shard_of key) key

let is_shard_name name =
  String.length name = fanout
  && String.for_all
       (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
       name

let chunks_seg = "/chunks/"

(* Derived rather than spelled, so the store's own root lives in exactly one
   place ({!Conf_parsing.root_prefix}) and this cannot drift from it.

   A domain named "corrupted", "verify-jobs" or "gc-jobs" would collide with
   these. Nothing forbids it; it has simply never been worth a check against
   three words. *)
let store_root ~chunk_prefix =
  match String.index_opt chunk_prefix '/' with
    | Some i -> String.sub chunk_prefix 0 (i + 1)
    | None -> ""

let corrupted_root ~chunk_prefix = store_root ~chunk_prefix ^ "corrupted/"
let verify_jobs_root ~chunk_prefix = store_root ~chunk_prefix ^ "verify-jobs/"
let gc_jobs_root ~chunk_prefix = store_root ~chunk_prefix ^ "gc-jobs/"

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

(* A sibling of the chunk root rather than a child: opening a run renames that
   root out of the way, so nothing that has to survive it can live inside. *)
let gc_marker_key ~chunk_prefix =
  Stored_key.in_space
    ~prefix:(Filename.chop_suffix chunk_prefix "chunks/")
    "gc-run"

(* Milliseconds, because a whole collection can begin and end inside one
   second. *)
let gc_run_name started = Printf.sprintf "%013.0f" (started *. 1000.)

(* A filesystem store keeps the directory a consumed request was filed under and
   lists it back, so what is asked is whether the leaf names a shard, not
   whether the key sits under the prefix. *)
let shard_of_job key =
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
  let key = Stored_key.to_string key in
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
                 && Chunks.is_chunk_key
                      (String.sub rest (j + 1) (String.length rest - j - 1)) ->
              Some
                (Stored_key.in_space
                   ~prefix:(String.sub root 0 (k + 1) ^ "corrupted/")
                   (String.sub root (k + 1) (String.length root - k - 1)
                   ^ "/" ^ rest))
          | _ -> None)

(* True for exactly what {!marker_key} produces. A directory is not a marker — a
   filesystem store makes one to hold markers and lists it back — so the whole
   shape is asked for, not the prefix. *)
let is_marker_key key =
  let key = Stored_key.to_string key in
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
                      && Chunks.is_chunk_key leaf
                  | None -> false))

let chunk_key_of_marker key = Filename.basename (Stored_key.to_string key)

module type Store = sig
  val chunk_prefix : string
end

module Make (S : Store) = struct
  let chunk_prefix = S.chunk_prefix
  let domain = domain_of ~chunk_prefix
  let domain_root = Filename.chop_suffix chunk_prefix "chunks/"
  let corrupted_prefix = corrupted_root ~chunk_prefix ^ domain ^ "/"

  let corrupted_key chunk_key =
    Stored_key.in_space ~prefix:corrupted_prefix (relative_path chunk_key)

  let verify_jobs_prefix = verify_jobs_root ~chunk_prefix ^ domain ^ "/"

  let verify_job_key shard =
    Stored_key.in_space ~prefix:verify_jobs_prefix shard

  let gc_jobs_prefix = gc_jobs_root ~chunk_prefix ^ domain ^ "/"

  (* The collection is in the name, not only the cursor: a later collection
     reaching the same shard would otherwise overwrite a request an earlier one
     left unconsumed, losing both its keys and the evidence that it stuck. *)
  let gc_job_key ~run name =
    Stored_key.in_space ~prefix:gc_jobs_prefix (run ^ "/" ^ name)

  let key chunk_key =
    Stored_key.in_space ~prefix:chunk_prefix (relative_path chunk_key)

  let shard_prefix shard = chunk_prefix ^ shard ^ "/"

  (* Siblings of the chunk root, since opening a collection renames that root
     itself away. *)
  let from_prefix = domain_root ^ "chunks.from/"

  let from_key chunk_key =
    Stored_key.in_space ~prefix:from_prefix (relative_path chunk_key)

  let from_shard_prefix shard = from_prefix ^ shard ^ "/"
end
