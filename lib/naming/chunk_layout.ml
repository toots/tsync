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

(* Content addressing in one expression: the name a body must be filed under.
   Here rather than with the manifest that publishes it, so the stores can hold a
   body against its own name without depending on the shapes that reference it. *)
let key_of_body data = Xxhash.hash_hex data 0 ^ "-" ^ Xxhash.hash_hex data 1

(* A chunk's key is a function of its bytes, so a store can hold every object it
   takes against the name it arrived under, and file the ones that fail where
   anyone can find them. The marker is the whole record: it exists, or the chunk
   was fine.

   A sibling of the chunk root rather than a child, so a collection renaming
   [chunks/] away ({!Chunk_space}) leaves the markers where they are, and so
   nothing walking chunks meets one. *)

let chunks_seg = "/chunks/"
let corrupted_seg = "/corrupted/"

let corrupted_prefix ~chunk_prefix =
  Filename.chop_suffix chunk_prefix "chunks/" ^ "corrupted/"

(* Last, not first: a domain named "chunks" would otherwise cut the key short. *)
let rfind_seg s seg =
  let n = String.length s and m = String.length seg in
  let rec go i =
    if i < 0 then None else if String.sub s i m = seg then Some i else go (i - 1)
  in
  if m > n then None else go (n - m)

(* Where a marker for the chunk object at [key] belongs, or [None] when [key]
   names something else.

   Two things fall out of matching [/chunks/] exactly, and both are load-bearing:
   a marker never earns one of its own, and neither does a chunk in the space a
   collection is moving out of — [corrupted/] and [chunks.from/] spell neither
   segment. That is the same non-recursion the bucket notification's prefix
   filter buys on the cloud side, held here so the two cannot disagree.

   Membership is this prefix and never the shape of the name: a manifest is filed
   under the hash of its own file name ({!Folder.hash_name}), so it is spelled
   exactly like a chunk key and would fail a hash-of-body check every time. *)
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

(* The mirror of {!marker_key}: true for exactly what it produces.

   A directory is not a marker, which is the whole reason this is not "starts
   with the prefix": a local store makes a shard directory to hold one and lists
   it back, and counting that as a finding would report a chunk corrupt whose
   name is not even there. *)
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
